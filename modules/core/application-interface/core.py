#!/usr/bin/env python3
"""Small JSON Lines adapter for supported Core operations."""

import json
import hashlib
from contextlib import contextmanager
import os
from pathlib import Path
import re
import signal
import select
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "bundle"))
import bundle
from execution import OwnedBootstrap
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from external_tool import diagnostic_valid
from reporting import opaque
import restore_selection
from secure import launch_channel, import_secure, SecureError

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


def restore_prepare(path, disabled_groups, include_secure, selection=None):
    with restore_signals(), prepared_restore(path, disabled_groups, include_secure, selection) as (summary, _stage, _source, _staged):
        return summary


@contextmanager
def prepared_restore(path, disabled_groups, include_secure, selection=None):
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
        try:
            restore_selection.narrow(stage, selection, disabled_groups)
        except restore_selection.InvalidSelection:
            raise InvalidSelection() from None
        bundle.narrow(stage, disabled_groups)
        stage_identity = bundle.fingerprint(stage)
        summary_file = private / "preview.summary"
        descriptor = os.open(summary_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(descriptor)
        plan_file = private / "preview.plan"
        plan_file.touch(mode=0o600)
        environment = dict(os.environ, BLUEPRINT_FILE=str(stage / "blueprint.conf"),
                           BLUEPRINT_GENERATED_DIR=str(stage / "generated"),
                           BUNDLE_RESTORE_PREVIEW="true", PREVIEW_SUMMARY_FILE=str(summary_file),
                           MACSEED_APPLICATION_EXECUTION="true", PREVIEW_PLAN_FILE=str(plan_file))
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
        if preview_status not in (0, 1, 2) or bundle.fingerprint(stage) != stage_identity:
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
        if preview_status == 2 and not any(item["status"] == "error" for item in modules):
            raise PreviewFailed()
        if not modules or any(item["status"] == "error" and not item["module"].startswith("preview_")
                              for item in modules):
            raise PreviewFailed()
        sections, categories = bundle.parse_blueprint((stage / "blueprint.conf").read_bytes())
        requirements = prepared_requirements(stage, include_secure)
        records = []
        domains = set(bundle.ITEMS) | set(bundle.CATEGORIES) | {"secure-ssh-identities"}
        for line in plan_file.read_text().splitlines():
            fields = line.split("\t")
            if len(fields) not in (5, 6) or fields[0] not in domains:
                raise PreviewFailed()
            domain, item, action, disposition, reason = fields[:5]
            capability = {}
            if len(fields) == 6:
                capability = json.loads(fields[5])
                if domain != 'homebrew-casks' or not isinstance(capability, dict):
                    raise PreviewFailed()
                keys = set(capability)
                if keys - {'qualification_id', 'authorization_required', 'diagnostic'}:
                    raise PreviewFailed()
                if disposition == 'planned' and not {'qualification_id', 'authorization_required'} <= keys:
                    raise PreviewFailed()
                if keys & {'qualification_id', 'authorization_required'}:
                    if (not {'qualification_id', 'authorization_required'} <= keys or
                            not PREPARED_PLAN_ID.fullmatch(str(capability['qualification_id'])) or
                            type(capability['authorization_required']) is not bool):
                        raise PreviewFailed()
                if 'diagnostic' in keys and not diagnostic_valid(capability['diagnostic']):
                    raise PreviewFailed()
            # Production inspection follows config section order, which need not
            # match Blueprint order. Correlate by section identity before exposing
            # the existing private numeric Protocol handle.
            if domain == "git-repositories":
                if item not in sections[domain]:
                    raise PreviewFailed()
                item = str(sections[domain].index(item) + 1)
            if action not in {"none", "install", "reinstall", "create_directory", "replace_with_backup",
                              "set_preference", "restart_process", "set_setting", "create", "clone", "switch_branch"} or disposition not in {
                              "satisfied", "planned", "blocked", "conflict", "warning"}:
                raise PreviewFailed()
            records.append({"domain": domain, "item_id": item, "action": action,
                            "disposition": disposition, "reason": None if reason == "none" else reason,
                            **capability})
        # Selected inventory is read by the existing validated Bundle parser.
        # Fill unobservable items, never invent an Apply decision from missing inspection.
        for domain in bundle.ITEMS:
            items = sections[domain]
            for index, item in enumerate(items, 1):
                identity = str(index) if domain == "git-repositories" else item
                if any(row["domain"] == domain and row["item_id"] == identity for row in records):
                    continue
                records.append({"domain": domain, "item_id": identity, "action": "inspect",
                                "disposition": "unknown", "reason": "inspection_unavailable"})
        for domain, enabled in categories.items():
            if enabled and (domain != "git-configuration" or sections[domain]) and not any(row["domain"] == domain for row in records):
                records.append({"domain": domain, "item_id": "scope", "action": "inspect",
                                "disposition": "unknown", "reason": "inspection_unavailable"})
        if include_secure:
            records.append({"domain": "secure-ssh-identities", "item_id": "encrypted_identity_set",
                            "action": "validate_and_import", "disposition": "pending_unlock",
                            "reason": "secure_unlock_required"})
        for row in records:
            if row["domain"] == "git-repositories":
                label = sections["git-repositories"][int(row["item_id"]) - 1]
                if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_. -]{0,127}", label, re.ASCII):
                    row["display_name"] = label
        # Correlate bounded provider context to the same selected item and reason.
        for condition in requirements['conditions']:
            index = condition.get('selected_item_index')
            if index is None:
                continue
            identity = sections[condition['domain']][index - 1]
            row = next((row for row in records if row['domain'] == condition['domain']
                        and row['item_id'] == identity and row['reason'] == condition['code']), None)
            if row and row.get('diagnostic'):
                condition['diagnostic'] = row['diagnostic']
        # Attach typed readiness reasons to dependent actions without changing Preview decisions.
        for condition in requirements["conditions"]:
            if condition["status"] in ("external_action_required", "unsupported"):
                for row in records:
                    selected_index = condition.get("selected_item_index")
                    if selected_index is not None and row["item_id"] != sections[condition["domain"]][selected_index - 1]:
                        continue
                    if row["domain"] == condition["domain"] and row["disposition"] in ("planned", "unknown", "blocked"):
                        row["disposition"] = "blocked"
                        row["reason"] = condition["code"]
        module_domains = {"preview_brew_packages": "homebrew-packages", "preview_brew_casks": "homebrew-casks",
                          "preview_appstore_apps": "app-store", "preview_vscode_extensions": "vscode-extensions",
                          "preview_git_configuration": "git-configuration", "preview_vscode_settings": "vscode-settings",
                          "preview_zsh": "shell-zsh", "preview_ssh_configuration": "ssh-configuration",
                          "preview_workspace_folders": "workspace-folders", "preview_workspace_repositories": "git-repositories",
                          "preview_macos_settings": "macOS Settings"}
        for module in modules:
            if module["status"] == "error":
                domain = module_domains[module["module"]]
                if not any(row["disposition"] == "blocked" for row in records) and requirements["ready"]:
                    raise PreviewFailed()
                requirements["ready"] = False
                requirements["conditions"].append({"domain": domain,
                    "code": "preview_observation_failed", "status": "external_action_required"})
        summary = {
            "selected_groups": [name for name, members in bundle.GROUPS.items()
                                if any(categories.get(member, False) or sections.get(member) for member in members)],
            "selected_categories": sorted(domain for domain, enabled in categories.items() if enabled),
            "selected_item_counts": {domain: len(sections[domain]) for domain in bundle.ITEMS},
            "include_secure": include_secure,
            "secure_restore_status": "selected_pending" if include_secure else "not_selected",
            "modules": modules,
            "plan": records,
            "readiness": requirements,
            "has_planned_changes": any(item["planned"] for item in modules) or include_secure,
            "has_executable_changes": any(row["disposition"] == "planned" for row in records) or include_secure,
            "warning_count": sum(item["status"] == "warning" for item in modules),
            "error_count": sum(item["status"] == "error" for item in modules),
            "preview_detail_level": "selected_requirements",
        }
        # Diagnostic tool provenance is not an exact-version plan requirement.
        # Conditions and normalized planning decisions remain identity-bound.
        identity_summary = dict(summary)
        identity_summary['readiness'] = {key: value for key, value in requirements.items()
                                        if key != 'external_tools'}
        identity = {"bundle": source_identity, "stage": stage_identity,
                    "disabled_groups": sorted(disabled_groups), "summary": identity_summary}
        if selection is not None:
            summary['selection'] = restore_selection.canonical(stage)
        summary["prepared_plan_id"] = hashlib.sha256(json.dumps(identity, sort_keys=True,
                                         separators=(",", ":")).encode()).hexdigest()
        # This identifies observed inputs and this module summary, never authorizes Apply.
        # Future Execute must rebuild and revalidate Preview before mutation.
        # Additive public fields after legacy identity calculation preserve old IDs.
        summary['selection'] = restore_selection.canonical(stage)
        restore_selection.correlate(summary['plan'], stage)
        yield summary, stage, source_identity, stage_identity


READINESS_CODES = {
    "ready", "authorization_required", "unsupported_interactive_operation",
    "vscode_cli_required", "vscode_cli_unavailable", "vscode_cli_ambiguous",
    "git_required", "git_unavailable", "repository_target_conflict",
    "ssh_configuration_not_ready", "ssh_configuration_observation_failed",
    "mas_required", "mas_unavailable", "age_required", "age_unavailable",
    "homebrew_installation_requires_interaction", "homebrew_unavailable",
    "homebrew_capability_unavailable", "homebrew_metadata_incompatible",
    "cask_launchctl_observation_failed",
    "privileged_lifecycle_unknown", "homebrew_platform_incompatible",
    "missing_required_dependency", "secure_bridge_required", "invalid_selected_input",
    "cask_metadata_unavailable", "cask_execution_requirements_unsupported",
    "cask_target_conflict", "cask_authorization_required", "cask_repair_not_supported",
    "internet_required", "command_line_tools_required",
}


def prepared_requirements(stage, include_secure):
    environment = dict(os.environ, BLUEPRINT_FILE=str(stage / "blueprint.conf"),
                       BLUEPRINT_GENERATED_DIR=str(stage / "generated"),
                       BUNDLE_RESTORE_ACTIVE="true", BUNDLE_RESTORE_SECURE_FILE="",
                       MACSEED_APPLICATION_EXECUTION="true",
                       MACSEED_APPLICATION_READINESS_REPORT="true",
                       MACSEED_APPLICATION_ALLOW_ITEM_SKIPS="true",
                       MACSEED_APPLICATION_SECURE_SELECTED=str(include_secure).lower(),
                       MACSEED_APPLICATION_SECURE_READY="true")
    child = subprocess.Popen(["./bootstrap.sh", "--application-readiness"], cwd=ROOT,
                             env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        output, _ = child.communicate(timeout=180)
    except BaseException as exc:
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
        if isinstance(exc, subprocess.TimeoutExpired):
            raise PreviewFailed() from None
        raise
    if child.returncode != 0:
        raise PreviewFailed()
    sections, _ = bundle.parse_blueprint(bundle.checked_file(stage / "blueprint.conf"))
    conditions = []
    for line in output.decode("ascii").splitlines():
        fields = line.split("\t")
        if len(fields) not in (2, 3) or fields[1] not in READINESS_CODES | {"homebrew_path_activation", "vscode_bundled_cli"}:
            raise PreviewFailed()
        domain, code = fields[:2]
        if code == "invalid_selected_input":
            raise PreviewFailed()
        status = ("satisfied" if code == "ready" else "safely_satisfiable" if code in {
                  "homebrew_path_activation", "vscode_bundled_cli"} else "unsupported" if code in {
                  "unsupported_interactive_operation", "cask_execution_requirements_unsupported",
                  "cask_repair_not_supported"} else "external_action_required")
        condition = {"domain": domain, "code": code, "status": status, "scope": "operation"}
        if len(fields) == 3:
            if (domain != "homebrew-casks" or not fields[2].isascii() or not fields[2].isdigit() or
                    not 1 <= int(fields[2]) <= len(sections[domain])):
                raise PreviewFailed()
            condition["selected_item_index"] = int(fields[2])
            if domain == "homebrew-casks" and code == "cask_execution_requirements_unsupported":
                condition["scope"] = "item"
        conditions.append(condition)
    if include_secure:
        # This is a launcher capability requirement, not a probe of an execution secret FD.
        # Preparation never consumes secrets or depends on an ephemeral channel's presence.
        conditions.append({"domain": "secure-ssh-identities", "code": "secure_bridge_required",
                           "status": "external_action_required", "scope": "execution_launch"})
    ready = all(row["status"] in ("satisfied", "safely_satisfiable") or
                row.get("scope") in ("execution_launch", "item") for row in conditions)
    external_tools = []
    for domain, kind in (("homebrew-packages", "formula"), ("homebrew-casks", "cask")):
        if not sections[domain]:
            continue
        probe = subprocess.run([sys.executable, '-B', str(ROOT / 'modules/apps/adapters/homebrew.py'),
                                'probe', kind], cwd=ROOT, env=environment,
                               stdin=subprocess.DEVNULL, capture_output=True, timeout=120)
        observed = json.loads(probe.stdout)
        observed['domain'] = domain
        external_tools.append(observed)
    compatibility_codes = {
        'homebrew_installation_requires_interaction': 'tool_unavailable',
        'homebrew_capability_unavailable': 'capability_unavailable',
        'homebrew_metadata_incompatible': 'metadata_incompatible',
        'homebrew_unavailable': 'observation_failure',
        'cask_metadata_unavailable': 'observation_failure',
        'cask_launchctl_observation_failed': 'observation_failure',
        'cask_execution_requirements_unsupported': 'item_unsupported',
    }
    for condition in conditions:
        if condition['code'] in compatibility_codes:
            condition['compatibility'] = compatibility_codes[condition['code']]
    return {"ready": ready, "ready_scope": "environment", "conditions": conditions,
            "external_tools": external_tools,
            "check_policy": "all_cask_item_conditions_then_first_operation_blocker_per_domain", "reentry": "restore_prepare"}


def readiness(stage, include_secure, secure_ready=False, secure_only=False):
    environment = dict(os.environ, BLUEPRINT_FILE=str(stage / "blueprint.conf"),
                       BLUEPRINT_GENERATED_DIR=str(stage / "generated"),
                       BUNDLE_RESTORE_ACTIVE="true", BUNDLE_RESTORE_SECURE_FILE="",
                       MACSEED_APPLICATION_EXECUTION="true",
                       MACSEED_APPLICATION_SECURE_SELECTED=str(include_secure).lower(),
                       MACSEED_APPLICATION_SECURE_READY=str(secure_ready).lower(),
                       MACSEED_APPLICATION_SECURE_ONLY=str(secure_only).lower(),
                       MACSEED_APPLICATION_ALLOW_ITEM_SKIPS="true")
    process = subprocess.Popen(["./bootstrap.sh", "--application-readiness"], cwd=ROOT,
                               env=environment, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               start_new_session=True)
    try:
        output, _ = process.communicate(timeout=180)
    except BaseException as exc:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        if isinstance(exc, subprocess.TimeoutExpired):
            raise ExecuteFailed("readiness_failed") from None
        raise
    fields = output.decode("ascii", errors="replace").strip().split("\t")
    status = fields[0]
    cask_conditions = {"cask_metadata_unavailable", "cask_execution_requirements_unsupported",
                       "cask_target_conflict", "cask_authorization_required", "cask_repair_not_supported",
                       "cask_launchctl_observation_failed"}
    item_index = None
    if len(fields) == 2 and status in cask_conditions and fields[1].isascii() and fields[1].isdigit():
        item_index = int(fields[1])
        if item_index < 1:
            raise ExecuteFailed("readiness_failed")
    elif len(fields) != 1 or status in cask_conditions:
        raise ExecuteFailed("readiness_failed")
    allowed = READINESS_CODES
    if status not in allowed or (process.returncode == 0) != (status == "ready"):
        raise ExecuteFailed("readiness_failed")
    if status != "ready":
        raise ExecuteFailed(status, item_index)


def restore_execute(operation_id, path, disabled_groups, include_secure, expected_id, channel=None, selection=None):
    sequence = 1  # started has already been emitted by main().
    state = {"prepared_plan_id": None, "execution_status": "not_started",
             "unknown_consequences": False,
             "publication_started": False, "publication_occurred": False,
             "target_mutation_may_have_started": False, "bootstrap_status": "not_started",
             "secure_restore_status": "selected_pending" if include_secure else "not_selected",
             "verification": {"status": "not_run", "verdict": "incomplete", "details": {
                 "status": "not_run", "verification_records": [], "coverage_records": [],
                 "operation_records": [], "diagnostics": [], "module_outcomes": []}},
             "warning_count": 0, "error_count": 0}
    owned = None

    def event(kind, data=None):
        nonlocal sequence
        sequence += 1
        emit(sequence, kind, operation_id, data)

    def record_event(kind, record):
        # Record events are additive; only completed/failed terminate an operation.
        event("execution_event" if kind == "lifecycle" else kind + "_record", record)

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
            with prepared_restore(path, disabled_groups, include_secure, selection) as (plan, stage, source_id, stage_id):
                event("phase_completed", {"phase": "preparation"})
                if plan["prepared_plan_id"] != expected_id:
                    raise ExecuteFailed("stale_plan")
                state["prepared_plan_id"] = plan["prepared_plan_id"]
                if not plan["has_executable_changes"] and any(
                        row.get("scope") == "item" for row in plan["readiness"]["conditions"]):
                    raise ExecuteFailed("no_executable_work")
                sections, categories = bundle.parse_blueprint((stage / "blueprint.conf").read_bytes())
                secure_only = include_secure and not any(categories.values()) and not any(
                    sections[name] for name in bundle.ITEMS)
                if include_secure and channel is not None:
                    if select.select([channel], [], [], 0)[0]:
                        raise SecureError("secure_cancelled" if not channel.recv(1, socket.MSG_PEEK)
                                          else "secure_channel_invalid")
                readiness(stage, include_secure, channel is not None, secure_only)
                if plan["error_count"]:
                    raise ExecuteFailed("preview_observation_failed")
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
                secure_evidence = None
                if include_secure:
                    def secure_mutation():
                        state["target_mutation_may_have_started"] = True
                        event("secure_publication_started")
                    state["secure_restore_status"] = "running"
                    secure_evidence = import_secure(ROOT, stage / "secure.age", channel,
                                                    operation_id, event, secure_mutation)
                    state["secure_restore_status"] = "completed"
                environment = dict(os.environ, BUNDLE_RESTORE_ACTIVE="true",
                                   BUNDLE_RESTORE_SECURE_FILE="application-evidence" if include_secure else "",
                                   MACSEED_APPLICATION_SECURE_SELECTED=str(include_secure).lower(),
                                   MACSEED_APPLICATION_SECURE_READY=str(include_secure).lower(),
                                   MACSEED_APPLICATION_SECURE_ONLY=str(secure_only).lower(),
                                   MACSEED_APPLICATION_ALLOW_ITEM_SKIPS="true")
                environment.pop("MACSEED_SECURE_EVIDENCE_FD", None)
                environment.pop("MACSEED_APPLICATION_SECURE_VERIFY_ONLY", None)
                for name in ("BLUEPRINT_FILE", "BLUEPRINT_GENERATED_DIR",
                             "SSH_SNAPSHOT_FILE", "ZSH_SNAPSHOT_FILE"):
                    environment.pop(name, None)
                event("phase_started", {"phase": "bootstrap"})
                try:
                    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK,
                                                            {signal.SIGINT, signal.SIGTERM})
                    try:
                        identities = {opaque(subject): str(index) for index, subject in
                                      enumerate(sections["git-repositories"], 1)}
                        skipped_casks = [row["item_id"] for row in plan["plan"]
                                         if row["domain"] == "homebrew-casks" and
                                         row["disposition"] == "blocked" and
                                         row["reason"] == "cask_execution_requirements_unsupported"]
                        owned = OwnedBootstrap(ROOT, environment, secure_evidence, record_event,
                                               identities, skipped_casks=skipped_casks,
                                               cask_plans={row['item_id']: row['qualification_id'] for row in plan['plan']
                                                           if row['domain'] == 'homebrew-casks' and row.get('qualification_id')})
                    finally:
                        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
                    bootstrap_exit = owned.wait()
                except BaseException:
                    if owned is not None:
                        owned.cancel()
                        state["target_mutation_may_have_started"] |= owned.mutation_may_have_started
                        state["verification"]["details"] = owned.details
                    raise
                state["target_mutation_may_have_started"] |= owned.mutation_may_have_started
                state['unknown_consequences'] = getattr(owned, 'unknown_consequences', False)
                if getattr(owned, 'external_lifecycle_cause', None):
                    state['external_lifecycle_cause'] = owned.external_lifecycle_cause
                state["bootstrap_status"] = ({0: "success", 1: "warning"}.get(bootstrap_exit, "failure"))
                if owned.verification is not None:
                    state["verification"] = {key: value for key, value in owned.verification.items()
                                             if not key.startswith("bootstrap_")}
                    state["warning_count"] = owned.verification["bootstrap_warning_count"]
                    state["error_count"] = owned.verification["bootstrap_error_count"]
                elif bootstrap_exit in (0, 1):
                    state["verification"] = {"status": "unavailable", "verdict": "incomplete"}
                    state["warning_count"] = 1 if bootstrap_exit == 1 else 0
                state["verification"]["details"] = owned.details
                if bootstrap_exit not in (0, 1):
                    state["independent_work_completed"] = owned.independent_work_completed
                    # Preserve typed authoritative outcomes alongside the compatible code.
                    state["operation_failures"] = [row for row in owned.details["operation_records"]
                                                   if row["outcome"] == "failure"]
                    raise ExecuteFailed('privileged_lifecycle_unknown' if state.get('unknown_consequences') else "bootstrap_failed")
                event("phase_completed", {"phase": "bootstrap"})
                state["execution_status"] = "completed"
                event("result", state)
                event("completed")
                return 0
    except SecureError as exc:
        receipt = getattr(exc, "evidence", None)
        if receipt is not None:
            environment = dict(os.environ, BUNDLE_RESTORE_ACTIVE="true",
                               BUNDLE_RESTORE_SECURE_FILE="application-evidence",
                               MACSEED_APPLICATION_SECURE_VERIFY_ONLY="true")
            for name in ("BLUEPRINT_FILE", "BLUEPRINT_GENERATED_DIR", "MACSEED_SECURE_EVIDENCE_FD"):
                environment.pop(name, None)
            try:
                with restore_signals():
                    observer = OwnedBootstrap(ROOT, environment, receipt, record_event)
                    try:
                        observer.wait()
                    except BaseException:
                        observer.cancel()
                        state["verification"]["details"] = observer.details
                        raise
                if observer.verification is not None:
                    state["verification"] = {key: value for key, value in observer.verification.items()
                                             if not key.startswith("bootstrap_")}
                state["verification"]["details"] = observer.details
            except Cancelled:
                state["secure_restore_status"] = "cancelled"
                return failure("cancelled", 130)
            except Exception:
                pass  # Missing verification cannot turn a failed import into success.
        state["secure_restore_status"] = "cancelled" if exc.code == "secure_cancelled" else "failed"
        return failure(exc.code, 130 if exc.code == "secure_cancelled" else 2)
    except ExecuteFailed as exc:
        if exc.code == 'privileged_lifecycle_unknown':
            state['unknown_consequences'] = True
        return failure(exc.code, selected_item_index=exc.selected_item_index)
    except RecoveryRequired:
        return failure("recovery_required")
    except InvalidSelection:
        return failure("invalid_selection")
    except PreviewFailed:
        return failure("preview_failed")
    except Cancelled:
        state['unknown_consequences'] = bool(owned and getattr(owned, 'unknown_consequences', False))
        return failure('privileged_lifecycle_unknown' if state['unknown_consequences'] else "cancelled", 130)
    except bundle.Unsupported:
        return failure("unsupported_bundle")
    except (FileNotFoundError, PermissionError):
        return failure("bundle_unavailable")
    except (bundle.Invalid, tarfile.TarError, ValueError, TypeError, KeyError, UnicodeError):
        return failure("publication_failed" if state["publication_started"] else "bundle_invalid")
    except Exception:
        return failure("internal_error")


def environment_compare(operation_id, parameters):
    sequence = 1
    owned = None
    state = {"read_only": True, "publication_occurred": False,
             "target_mutation_may_have_started": False}

    def event(kind, data=None):
        nonlocal sequence
        sequence += 1
        emit(sequence, kind, operation_id, data)

    try:
        with restore_signals(), tempfile.TemporaryDirectory(prefix="macseed-compare-") as temporary:
            generated = Path(parameters["generated_dir"])
            blueprint = parameters["blueprint_path"]
            if not generated.is_dir() or not os.access(generated, os.R_OK | os.X_OK):
                raise ExecuteFailed("reference_unavailable")
            if blueprint is not None and (not Path(blueprint).is_file() or not os.access(blueprint, os.R_OK)):
                raise ExecuteFailed("reference_unavailable")
            environment = os.environ.copy()
            # Reference is explicit. No ambient Restore/evidence or snapshot override.
            for name in tuple(environment):
                if name.startswith(("BUNDLE_RESTORE_", "MACSEED_", "BLUEPRINT_")) or name in {
                        "ZSH_SNAPSHOT_FILE", "SSH_SNAPSHOT_FILE", "PREVIEW_PLAN_FILE"}:
                    environment.pop(name, None)
            environment.update(BLUEPRINT_GENERATED_DIR=str(generated),
                               BLUEPRINT_FILE=blueprint or str(Path(temporary) / "absent-blueprint"),
                               MACSEED_APPLICATION_COMPARE="true", MAS_NO_AUTO_INDEX="1",
                               HOMEBREW_NO_AUTO_UPDATE="1", PYTHONDONTWRITEBYTECODE="1")
            def progress(kind, record):
                if kind == "lifecycle":
                    event("execution_event", dict(record, read_only=True))

            owned = OwnedBootstrap(ROOT, environment, on_record=progress, mode="--application-compare")
            try:
                status = owned.wait()
            except BaseException:
                owned.cancel()
                raise
            state.update(comparison=owned.comparison, comparison_records=owned.comparison_records,
                         extra={"domains": owned.extra_status, "items": owned.extra_records},
                         verification=owned.verification, records=owned.details)
            if owned.details["status"] != "complete" or owned.comparison is None or owned.verification is None:
                raise ExecuteFailed("comparison_reporting_incomplete")
            event("result", state)
            if status != 0:
                codes = {row["code"] for row in owned.details["diagnostics"]}
                raise ExecuteFailed("reference_invalid" if "input_invalid" in codes else
                                    "reference_changed" if "input_changed" in codes else "comparison_failed")
            event("completed", {"read_only": True, "target_mutation_may_have_started": False})
            return 0
    except Cancelled:
        if owned is not None:
            state.update(comparison=owned.comparison, comparison_records=owned.comparison_records,
                         extra={"domains": owned.extra_status, "items": owned.extra_records},
                         verification=owned.verification, records=owned.details)
        event("cancelled", state)
        return 130
    except ExecuteFailed as exc:
        event("failed", dict(state, code=exc.code))
        return 2
    except OSError:
        event("failed", dict(state, code="comparison_unavailable"))
        return 2
    except Exception:
        event("failed", dict(state, code="internal_error"))
        return 2


def main(version, channel=None):
    operation_id = None
    for name in ("MACSEED_APPLICATION_SECURE_READY", "MACSEED_APPLICATION_SECURE_ONLY",
                 "MACSEED_APPLICATION_SECURE_VERIFY_ONLY", "MACSEED_SECURE_EVIDENCE_FD",
                 "MACSEED_SECURE_ATTEMPT", "MACSEED_SECURE_EXIT", "MACSEED_REPORT_FD",
                 "MACSEED_REPORT_COUNT", "MACSEED_REPORT_INVALID", "MACSEED_APPLICATION_CAPTURE",
                 "MACSEED_CAPTURE_INVENTORY"):
        os.environ.pop(name, None)
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
        elif operation == "environment_compare":
            if set(value) != required | {"parameters"} or not isinstance(value["parameters"], dict):
                raise ValueError("invalid Compare request")
            parameters = value["parameters"]
            if set(parameters) != {"generated_dir", "blueprint_path"}:
                raise ValueError("invalid reference")
            for name in ("generated_dir", "blueprint_path"):
                path_value = parameters[name]
                if name == "blueprint_path" and path_value is None:
                    continue
                if not isinstance(path_value, str) or not path_value.startswith("/") or "\0" in path_value:
                    raise ValueError("invalid reference path")
        elif operation in ("capture_prepare", "capture_execute"):
            if set(value) != required | {"parameters"} or not isinstance(value['parameters'], dict):
                raise ValueError('invalid Capture parameters')
            parameters = value['parameters']
            expected = {'selection'} if operation == 'capture_prepare' else {'selection', 'destination', 'expected_prepared_capture_id'}
            replacement = operation == 'capture_execute' and set(parameters) == expected | {'replacement_sha256'}
            if (set(parameters) != expected and not replacement) or (operation == 'capture_execute' and parameters['selection'] is None):
                raise ValueError('invalid Capture parameters')
            if replacement and (not isinstance(parameters['replacement_sha256'], str) or not PREPARED_PLAN_ID.fullmatch(parameters['replacement_sha256'])):
                raise ValueError('invalid Capture replacement fingerprint')
            if operation == 'capture_execute' and (not isinstance(parameters['expected_prepared_capture_id'], str) or
                    not PREPARED_PLAN_ID.fullmatch(parameters['expected_prepared_capture_id'])):
                raise ValueError('invalid Capture prepared ID')
        elif operation in ("bundle_inspect", "restore_prepare", "restore_execute"):
            if set(value) != required | {"parameters"}:
                raise ValueError("invalid Bundle request")
            parameters = value["parameters"]
            expected = {"path"} if operation == "bundle_inspect" else {"path", "disabled_groups", "include_secure"}
            if operation == "restore_execute":
                expected = expected | {"expected_prepared_plan_id"}
            if not isinstance(parameters, dict) or (set(parameters) != expected and not (operation != "bundle_inspect" and set(parameters) == expected | {"selection"})):
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

    if channel is not None and operation != "capture_execute" and (operation != "restore_execute" or not include_secure):
        channel.close()
        channel = None
    emit(1, "started", operation_id)
    if operation == "environment_compare":
        return environment_compare(operation_id, parameters)
    if operation in ('capture_prepare', 'capture_execute'):
        from capture import capture, CaptureError
        sequence = 1
        def capture_event(kind, data=None):
            nonlocal sequence
            sequence += 1
            emit(sequence, kind, operation_id, data)
        parameters['_operation_id'] = operation_id
        try:
            with restore_signals():
                return capture(ROOT, operation, parameters, channel, capture_event)
        except CaptureError as exc:
            capture_event('failed', {'code': exc.code, 'publication_occurred': False})
            return 2
    if operation == "restore_execute":
        if len(disabled_groups) != len(set(disabled_groups)) or any(item not in bundle.GROUPS for item in disabled_groups):
            emit(2, "failed", operation_id, {"code": "invalid_selection",
                                               "publication_occurred": False,
                                               "target_mutation_may_have_started": False})
            return 2
        return restore_execute(operation_id, path, disabled_groups, include_secure, expected_id, channel, parameters.get("selection"))
    if operation == "capabilities":
        result = {
            "protocol_version": PROTOCOL_VERSION,
            "product_version": version,
            "features": {"restore_selection": {"version": 1, "inventory": "bundle_inspect", "selection_modes": ["category", "items"]}},
            "operations": ["capabilities", "bundle_inspect", "restore_prepare", "restore_execute", "capture_prepare", "capture_execute", "environment_compare"],
        }
    else:
        try:
            if operation == "restore_prepare":
                if len(disabled_groups) != len(set(disabled_groups)) or any(item not in bundle.GROUPS for item in disabled_groups):
                    raise InvalidSelection()
                result = restore_prepare(path, disabled_groups, include_secure, parameters.get("selection"))
            else:
                input_path = Path(path)
                mode = input_path.lstat().st_mode
                if not stat.S_ISREG(mode):
                    raise bundle.Invalid("unsafe Bundle input")
                source_identity = bundle.fingerprint(input_path)
                result = bundle.inspect_bundle(input_path, os.environ["HOME"])
                result["restore_selection"], _ = restore_selection.inventory(bundle.validate_archive(input_path))
                if bundle.fingerprint(input_path) != source_identity:
                    raise bundle.Invalid("Bundle changed during inspection")
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
    channel = launch_channel(sys.argv[2:])
    try:
        result = main(sys.argv[1], channel)
    finally:
        if channel is not None:
            channel.close()
    sys.exit(result)
