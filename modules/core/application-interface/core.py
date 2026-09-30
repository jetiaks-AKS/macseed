#!/usr/bin/env python3
"""Small JSON Lines adapter for supported Core operations."""

import json
import hashlib
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

PROTOCOL_VERSION = 1
MAX_REQUEST = 4096
OPERATION_ID = re.compile(r"[A-Za-z0-9_-]{1,64}\Z", re.ASCII)
ROOT = Path(__file__).resolve().parents[3]


class RecoveryRequired(Exception):
    pass


class InvalidSelection(Exception):
    pass


class PreviewFailed(Exception):
    pass


class Cancelled(Exception):
    pass


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


def restore_prepare(path, disabled_groups, include_secure):
    def cancel(_signum, _frame):
        raise Cancelled()

    previous_int = signal.signal(signal.SIGINT, cancel)
    previous_term = signal.signal(signal.SIGTERM, cancel)
    try:
        return _restore_prepare(path, disabled_groups, include_secure)
    finally:
        signal.signal(signal.SIGINT, previous_int)
        signal.signal(signal.SIGTERM, previous_term)


def _restore_prepare(path, disabled_groups, include_secure):
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
                           BUNDLE_RESTORE_PREVIEW="true", PREVIEW_SUMMARY_FILE=str(summary_file))
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
        return summary


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
        elif operation in ("bundle_inspect", "restore_prepare"):
            if set(value) != required | {"parameters"}:
                raise ValueError("invalid Bundle request")
            parameters = value["parameters"]
            expected = {"path"} if operation == "bundle_inspect" else {"path", "disabled_groups", "include_secure"}
            if not isinstance(parameters, dict) or set(parameters) != expected:
                raise ValueError("invalid Bundle parameters")
            path = parameters["path"]
            if not isinstance(path, str) or not path.startswith("/") or "\0" in path:
                raise ValueError("invalid Bundle path")
            if operation == "restore_prepare":
                disabled_groups = parameters["disabled_groups"]
                include_secure = parameters["include_secure"]
                if not isinstance(disabled_groups, list) or not all(isinstance(item, str) for item in disabled_groups) or type(include_secure) is not bool:
                    raise ValueError("invalid Restore selection types")
        else:
            emit(1, "failed", operation_id, {"code": "unsupported_operation"})
            return 2
    except (KeyError, ValueError, UnicodeError):
        emit(1, "failed", operation_id, {"code": "invalid_request"})
        return 2

    emit(1, "started", operation_id)
    if operation == "capabilities":
        result = {
            "protocol_version": PROTOCOL_VERSION,
            "product_version": version,
            "operations": ["capabilities", "bundle_inspect", "restore_prepare"],
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
