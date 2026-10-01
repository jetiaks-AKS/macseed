#!/usr/bin/env python3
"""Small JSON Lines adapter for supported Core operations."""

import json
import hashlib
from contextlib import contextmanager
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bundle"))
import bundle
from execution import OwnedBootstrap

PROTOCOL_VERSION = 1
MAX_REQUEST = 4096
OPERATION_ID = re.compile(r"[A-Za-z0-9_-]{1,64}\Z", re.ASCII)
PREPARED_PLAN_ID = re.compile(r"[0-9a-f]{64}\Z", re.ASCII)
ROOT = Path(__file__).resolve().parents[3]


class RecoveryRequired(Exception):
    pass


class InvalidSelection(Exception):
    pass


class PreviewFailed(Exception):
    pass


class Cancelled(Exception):
    pass


class ExecuteFailed(Exception):
    def __init__(self, code, selected_item_index=None):
        self.code = code
        self.selected_item_index = selected_item_index


def emit(sequence, kind, operation_id, data=None):
    record = {
        "protocol_version": PROTOCOL_VERSION,
        "operation_id": operation_id,
        "sequence": sequence,
        "type": kind,
    }
    if data is not None:
        record["data"] = data
    print(json.dumps(record, ensure_ascii=True, separators=(",", ":")), flush=True)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def request():
    raw = sys.stdin.buffer.read(MAX_REQUEST + 1)
    if not raw or len(raw) > MAX_REQUEST:
        raise ValueError("empty or oversized request")
    value = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
    if not isinstance(value, dict):
        raise ValueError("invalid request shape")
    return value


@contextmanager
def restore_signals():
    def cancel(_signum, _frame):
        raise Cancelled()

    previous_int = signal.signal(signal.SIGINT, cancel)
    previous_term = signal.signal(signal.SIGTERM, cancel)
    try:
        yield
    finally:
        signal.signal(signal.SIGINT, previous_int)
        signal.signal(signal.SIGTERM, previous_term)


def restore_prepare(path, disabled_groups, include_secure):
    with restore_signals(), prepared_restore(path, disabled_groups, include_secure) as (summary, _stage, _source, _staged):
        return summary


@contextmanager
def prepared_restore(path, disabled_groups, include_secure):
    if bundle.RECOVERY.exists() or bundle.RECOVERY.is_symlink():
        raise RecoveryRequired()
    input_path = Path(path)
    if not stat.S_ISREG(input_path.lstat().st_mode):
        raise bundle.Invalid("unsafe Bundle input")
    bundle.inspect_bundle(input_path, os.environ["HOME"])
    source_identity = bundle.fingerprint(input_path)
    with tempfile.TemporaryDirectory(prefix="mbt-bundle-", dir=os.environ.get("TMPDIR") or "/tmp") as temporary:
        private = Path(temporary)
        stage = private / "stage"
        stage.mkdir(mode=0o700)
        bundle.unpack(input_path, stage, os.environ["HOME"])
        if bundle.fingerprint(input_path) != source_identity:
            raise bundle.Invalid("Bundle changed during preparation")
        if include_secure and not (stage / "secure.age").is_file():
            raise InvalidSelection()
        bundle.narrow(stage, disabled_groups)
        stage_identity = bundle.fingerprint(stage)
        summary_file = private / "preview.summary"
        descriptor = os.open(summary_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(descriptor)
        environment = dict(os.environ, BLUEPRINT_FILE=str(stage / "blueprint.conf"),
                           BLUEPRINT_GENERATED_DIR=str(stage / "generated"),
                           BUNDLE_RESTORE_PREVIEW="true", PREVIEW_SUMMARY_FILE=str(summary_file),
                           MACSEED_APPLICATION_EXECUTION="true")
        preview = subprocess.Popen(["./bootstrap.sh", "--dry-run"], cwd=ROOT, env=environment,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            preview_status = preview.wait()
        except BaseException:
            if preview.poll() is None:
                try:
                    os.killpg(preview.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    preview.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(preview.pid, signal.SIGKILL)
                    preview.wait()
            raise
        if bundle.RECOVERY.exists() or bundle.RECOVERY.is_symlink():
            raise RecoveryRequired()
        if preview_status not in (0, 1) or bundle.fingerprint(stage) != stage_identity:
            raise PreviewFailed()
        if bundle.fingerprint(input_path) != source_identity:
            raise bundle.Invalid("Bundle changed during preparation")
        modules = []
        for line in summary_file.read_text().splitlines():
            fields = line.split("\t")
            if len(fields) != 3 or fields[1] not in ("0", "1", "2") or fields[2] not in ("true", "false"):
                raise PreviewFailed()
            modules.append({"module": fields[0], "status": {"0": "success", "1": "warning", "2": "error"}[fields[1]],
                            "planned": fields[2] == "true"})
        if not modules or any(item["status"] == "error" for item in modules):
            raise PreviewFailed()
        summary = {
            "selected_groups": [name for name in bundle.GROUPS if name not in disabled_groups],
            "include_secure": include_secure,
            "secure_restore_status": "selected_pending" if include_secure else "not_selected",
            "modules": modules,
            "has_planned_changes": any(item["planned"] for item in modules),
            "warning_count": sum(item["status"] == "warning" for item in modules),
            "error_count": 0,
            "preview_detail_level": "module_summary",
        }
        identity = {"bundle": source_identity, "stage": stage_identity,
                    "disabled_groups": sorted(disabled_groups), "summary": summary}
        summary["prepared_plan_id"] = hashlib.sha256(json.dumps(identity, sort_keys=True,
                                         separators=(",", ":")).encode()).hexdigest()
        # This identifies observed inputs and this module summary, never authorizes Apply.
        # Future Execute must rebuild and revalidate Preview before mutation.
        yield summary, stage, source_identity, stage_identity


def readiness(stage, include_secure):
    environment = dict(os.environ, BLUEPRINT_FILE=str(stage / "blueprint.conf"),
                       BLUEPRINT_GENERATED_DIR=str(stage / "generated"),
                       BUNDLE_RESTORE_ACTIVE="true", BUNDLE_RESTORE_SECURE_FILE="",
                       MACSEED_APPLICATION_EXECUTION="true",
                       MACSEED_APPLICATION_SECURE_SELECTED=str(include_secure).lower())
    process = subprocess.Popen(["./bootstrap.sh", "--application-readiness"], cwd=ROOT,
                               env=environment, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               start_new_session=True)
    try:
        output, _ = process.communicate()
    except BaseException:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        raise
    fields = output.decode("ascii", errors="replace").strip().split("\t")
    status = fields[0]
    cask_conditions = {"cask_metadata_unavailable", "cask_execution_requirements_unsupported",
                       "cask_target_conflict", "cask_authorization_required", "cask_repair_not_supported"}
    item_index = None
    if len(fields) == 2 and status in cask_conditions and fields[1].isascii() and fields[1].isdigit():
        item_index = int(fields[1])
        if item_index < 1:
            raise ExecuteFailed("readiness_failed")
    elif len(fields) != 1 or status in cask_conditions:
        raise ExecuteFailed("readiness_failed")
    allowed = {"ready", "authorization_required", "unsupported_interactive_operation",
               "vscode_cli_required", "vscode_cli_unavailable", "vscode_cli_ambiguous",
               "git_required", "git_unavailable", "repository_target_conflict",
               "homebrew_installation_requires_interaction", "homebrew_unavailable",
               "missing_required_dependency", "secure_bridge_required", "invalid_selected_input"}
    allowed |= cask_conditions
    if status not in allowed or (process.returncode == 0) != (status == "ready"):
        raise ExecuteFailed("readiness_failed")
    if status != "ready":
        raise ExecuteFailed(status, item_index)


def restore_execute(operation_id, path, disabled_groups, include_secure, expected_id):
    sequence = 1  # started has already been emitted by main().
    state = {"prepared_plan_id": None, "execution_status": "not_started",
             "publication_started": False, "publication_occurred": False,
             "target_mutation_may_have_started": False, "bootstrap_status": "not_started",
             "secure_restore_status": "selected_pending" if include_secure else "not_selected",
             "verification": {"status": "not_run", "verdict": "incomplete"},
             "warning_count": 0, "error_count": 0}
    owned = None

    def event(kind, data=None):
        nonlocal sequence
        sequence += 1
        emit(sequence, kind, operation_id, data)

    def failure(code, exit_status=2, selected_item_index=None):
        state["execution_status"] = ("failed_after_mutation_may_have_started"
                                     if state["target_mutation_may_have_started"]
                                     else "failed_before_mutation")
        state["error_count"] = max(1, state["error_count"])
        data = dict(state, code=code)
        if selected_item_index is not None:
            data.update(category="homebrew-casks", selected_item_index=selected_item_index)
        event("failed", data)
        return exit_status

    try:
        with restore_signals():
            event("phase_started", {"phase": "preparation"})
            with prepared_restore(path, disabled_groups, include_secure) as (plan, stage, source_id, stage_id):
                event("phase_completed", {"phase": "preparation"})
                if plan["prepared_plan_id"] != expected_id:
                    raise ExecuteFailed("stale_plan")
                state["prepared_plan_id"] = plan["prepared_plan_id"]
                readiness(stage, include_secure)
                if (bundle.fingerprint(stage) != stage_id or
                    bundle.fingerprint(Path(path)) != source_id):
                    raise ExecuteFailed("stale_plan")
                if bundle.RECOVERY.exists() or bundle.RECOVERY.is_symlink():
                    raise RecoveryRequired()
                event("phase_started", {"phase": "publication"})
                state["publication_started"] = True
                previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK,
                                                        {signal.SIGINT, signal.SIGTERM})
                try:
                    bundle.publish(stage)
                    state["publication_occurred"] = True
                finally:
                    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
                event("phase_completed", {"phase": "publication"})
                environment = dict(os.environ, BUNDLE_RESTORE_ACTIVE="true",
                                   BUNDLE_RESTORE_SECURE_FILE="")
                for name in ("BLUEPRINT_FILE", "BLUEPRINT_GENERATED_DIR",
                             "SSH_SNAPSHOT_FILE", "ZSH_SNAPSHOT_FILE"):
                    environment.pop(name, None)
                event("phase_started", {"phase": "bootstrap"})
                try:
                    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK,
                                                            {signal.SIGINT, signal.SIGTERM})
                    try:
                        owned = OwnedBootstrap(ROOT, environment)
                    finally:
                        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
                    bootstrap_exit = owned.wait()
                except BaseException:
                    if owned is not None:
                        owned.cancel()
                        state["target_mutation_may_have_started"] = owned.mutation_may_have_started
                    raise
                state["target_mutation_may_have_started"] = owned.mutation_may_have_started
                state["bootstrap_status"] = ({0: "success", 1: "warning"}.get(bootstrap_exit, "failure"))
                if owned.verification is not None:
                    state["verification"] = {key: value for key, value in owned.verification.items()
                                             if not key.startswith("bootstrap_")}
                    state["warning_count"] = owned.verification["bootstrap_warning_count"]
                    state["error_count"] = owned.verification["bootstrap_error_count"]
                elif bootstrap_exit in (0, 1):
                    state["verification"] = {"status": "unavailable", "verdict": "incomplete"}
                    state["warning_count"] = 1 if bootstrap_exit == 1 else 0
                if bootstrap_exit not in (0, 1):
                    raise ExecuteFailed("bootstrap_failed")
                event("phase_completed", {"phase": "bootstrap"})
                state["execution_status"] = "completed"
                event("result", state)
                event("completed")
                return 0
    except ExecuteFailed as exc:
        return failure(exc.code, selected_item_index=exc.selected_item_index)
    except RecoveryRequired:
        return failure("recovery_required")
    except InvalidSelection:
        return failure("invalid_selection")
    except PreviewFailed:
        return failure("preview_failed")
    except Cancelled:
        return failure("cancelled", 130)
    except bundle.Unsupported:
        return failure("unsupported_bundle")
    except (FileNotFoundError, PermissionError):
        return failure("bundle_unavailable")
    except (bundle.Invalid, tarfile.TarError, ValueError, TypeError, KeyError, UnicodeError):
        return failure("publication_failed" if state["publication_started"] else "bundle_invalid")
    except Exception:
        return failure("internal_error")


def main(version):
    operation_id = None
    try:
        value = request()
        candidate = value["operation_id"]
        if not isinstance(candidate, str) or not OPERATION_ID.fullmatch(candidate):
            raise ValueError("invalid operation id")
        operation_id = candidate
        if type(value["protocol_version"]) is not int or value["protocol_version"] != PROTOCOL_VERSION:
            code = "unsupported_protocol" if type(value["protocol_version"]) is int else "invalid_request"
            emit(1, "failed", operation_id, {"code": code})
            return 2
        if not isinstance(value["operation"], str):
            raise ValueError("invalid operation")
        operation = value["operation"]
        required = {"protocol_version", "operation_id", "operation"}
        if operation == "capabilities":
            if set(value) != required:
                raise ValueError("invalid capabilities request")
        elif operation in ("bundle_inspect", "restore_prepare", "restore_execute"):
            if set(value) != required | {"parameters"}:
                raise ValueError("invalid Bundle request")
            parameters = value["parameters"]
            expected = {"path"} if operation == "bundle_inspect" else {"path", "disabled_groups", "include_secure"}
            if operation == "restore_execute":
                expected = expected | {"expected_prepared_plan_id"}
            if not isinstance(parameters, dict) or set(parameters) != expected:
                raise ValueError("invalid Bundle parameters")
            path = parameters["path"]
            if not isinstance(path, str) or not path.startswith("/") or "\0" in path:
                raise ValueError("invalid Bundle path")
            if operation in ("restore_prepare", "restore_execute"):
                disabled_groups = parameters["disabled_groups"]
                include_secure = parameters["include_secure"]
                if not isinstance(disabled_groups, list) or not all(isinstance(item, str) for item in disabled_groups) or type(include_secure) is not bool:
                    raise ValueError("invalid Restore selection types")
                if operation == "restore_execute":
                    expected_id = parameters["expected_prepared_plan_id"]
                    if not isinstance(expected_id, str) or not PREPARED_PLAN_ID.fullmatch(expected_id):
                        raise ValueError("invalid prepared plan ID")
        else:
            emit(1, "failed", operation_id, {"code": "unsupported_operation"})
            return 2
    except (KeyError, ValueError, UnicodeError):
        emit(1, "failed", operation_id, {"code": "invalid_request"})
        return 2

    emit(1, "started", operation_id)
    if operation == "restore_execute":
        if len(disabled_groups) != len(set(disabled_groups)) or any(item not in bundle.GROUPS for item in disabled_groups):
            emit(2, "failed", operation_id, {"code": "invalid_selection",
                                               "publication_occurred": False,
                                               "target_mutation_may_have_started": False})
            return 2
        return restore_execute(operation_id, path, disabled_groups, include_secure, expected_id)
    if operation == "capabilities":
        result = {
            "protocol_version": PROTOCOL_VERSION,
            "product_version": version,
            "operations": ["capabilities", "bundle_inspect", "restore_prepare", "restore_execute"],
        }
    else:
        try:
            if operation == "restore_prepare":
                if len(disabled_groups) != len(set(disabled_groups)) or any(item not in bundle.GROUPS for item in disabled_groups):
                    raise InvalidSelection()
                result = restore_prepare(path, disabled_groups, include_secure)
            else:
                input_path = Path(path)
                mode = input_path.lstat().st_mode
                if not stat.S_ISREG(mode):
                    raise bundle.Invalid("unsafe Bundle input")
                result = bundle.inspect_bundle(input_path, os.environ["HOME"])
        except RecoveryRequired:
            emit(2, "failed", operation_id, {"code": "recovery_required"})
            return 2
        except InvalidSelection:
            emit(2, "failed", operation_id, {"code": "invalid_selection"})
            return 2
        except PreviewFailed:
            emit(2, "failed", operation_id, {"code": "preview_failed"})
            return 2
        except Cancelled:
            emit(2, "failed", operation_id, {"code": "cancelled"})
            return 130
        except bundle.Unsupported:
            emit(2, "failed", operation_id, {"code": "unsupported_bundle"})
            return 2
        except (FileNotFoundError, PermissionError):
            emit(2, "failed", operation_id, {"code": "bundle_unavailable"})
            return 2
        except (bundle.Invalid, tarfile.TarError, ValueError, TypeError, KeyError, UnicodeError):
            emit(2, "failed", operation_id, {"code": "bundle_invalid"})
            return 2
        except Exception:
            emit(2, "failed", operation_id, {"code": "internal_error"})
            return 2
    emit(2, "result", operation_id, result)
    emit(3, "completed", operation_id)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
