"""Owned, non-interactive production subprocess for future Core execution."""

import os
import json
import re
import select
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from reporting import MAX_LINE, MAX_RECORDS, item
import signal
import subprocess
import tempfile
import time
from item_execution import ProcessTree, process_table


class OwnedBootstrap:
    def __init__(self, root, environment, secure_evidence=None, on_record=None, identities=None, mode="--bootstrap", skipped_casks=None, cask_plans=None):
        if mode not in {"--bootstrap", "--application-compare"}:
            raise ValueError("unsupported owned mode")
        if mode == "--bootstrap":
            # Observation capability must be checked before starting a mutating child.
            process_table()
        read_fd, write_fd = os.pipe()
        verification_read, verification_write = os.pipe()
        report_read, report_write = os.pipe()
        self.mode = mode
        self.comparison = None
        self.comparison_records = []
        self.extra_status = []
        self.extra_records = []
        self.report_fd = report_read
        os.set_blocking(report_read, False)
        self.on_record = on_record
        self.identities = identities or {}
        self.details = {"status": "partial", "verification_records": [], "coverage_records": [],
                        "operation_records": [], "diagnostics": [], "module_outcomes": []}
        self.report_buffer = b""
        self.report_count = 0
        self.reporting_invalid = False
        self.item_state = tempfile.TemporaryDirectory(prefix='macseed-items-', dir='/private/tmp')
        os.chmod(self.item_state.name, 0o700)
        child_env = dict(environment)
        child_env.update(MACSEED_APPLICATION_EXECUTION="true", MACSEED_ITEM_STATE_DIR=self.item_state.name,
                         MACSEED_EXECUTION_SIGNAL_FD=str(write_fd),
                         MACSEED_VERIFICATION_FD=str(verification_write),
                         MACSEED_REPORT_FD=str(report_write), MACSEED_REPORT_COUNT="0", MACSEED_REPORT_INVALID="false")
        receipt = None
        descriptors = (write_fd, verification_write, report_write)
        if secure_evidence is not None:
            raw, attempt, status = secure_evidence
            receipt = tempfile.TemporaryFile(dir='/private/tmp')
            receipt.write(raw)
            receipt.seek(0)
            child_env.update(MACSEED_SECURE_EVIDENCE_FD=str(receipt.fileno()),
                             MACSEED_SECURE_ATTEMPT=attempt, MACSEED_SECURE_EXIT=str(status))
            descriptors += (receipt.fileno(),)
        try:
            skipped_file = Path(self.item_state.name) / 'skipped-casks.json'
            descriptor = os.open(skipped_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, 'w') as stream:
                json.dump(skipped_casks or [], stream)
            descriptor = os.open(Path(self.item_state.name) / 'prepared-casks.json', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, 'w') as stream:
                json.dump(cask_plans or {}, stream)
            self.process = subprocess.Popen(
                ["./bootstrap.sh", mode], cwd=root, env=child_env,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, start_new_session=True,
                pass_fds=descriptors)
        except BaseException:
            if mode == "--application-compare" and getattr(self, "process", None) is not None:
                try:
                    os.killpg(self.process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                self.process.wait()
            self.item_state.cleanup()
            if receipt is not None:
                receipt.close()
            os.close(read_fd)
            os.close(write_fd)
            os.close(verification_read)
            os.close(verification_write)
            os.close(report_read)
            os.close(report_write)
            raise
        if receipt is not None:
            receipt.close()
        os.close(write_fd)
        os.close(verification_write)
        os.close(report_write)
        self.signal_fd = read_fd
        self.verification_fd = verification_read
        self.tree = ProcessTree(self.process.pid, initialize=False) if mode == "--bootstrap" else None
        self.last_tree_scan = time.monotonic() - .5
        self.mutation_may_have_started = False
        self.verification = None

    def _record(self, record):
        if getattr(self, "mode", None) == "--application-compare" and isinstance(record, dict) and record.get("kind") in {
                "comparison", "comparison_summary", "extra", "extra_status"}:
            # Already privacy-projected by reporting.py, on an owned private FD.
            self.report_count += 1
            if self.report_count > MAX_RECORDS:
                self.details["status"] = "truncated"
                return
            kind = record["kind"]
            schemas = {
                "comparison": {"record_id", "domain", "item_id", "comparison_kind", "reason", "phase", "support"},
                "extra": {"domain", "item_id"},
                "extra_status": {"domain", "status", "count", "reason"},
                "comparison_summary": {"status", "verdict", "also_incomplete", "counts"},
            }
            if set(record) != schemas[kind] | {"kind"}:
                self.reporting_invalid = True
                return
            if kind == "comparison_summary":
                counts = record["counts"]
                if (record["status"] not in {"complete", "incomplete"} or record["verdict"] not in {
                        "incomplete", "differences_detected", "no_differences_detected", "no_comparable_requirements"} or
                        type(record["also_incomplete"]) is not bool or not isinstance(counts, dict) or
                        set(counts) != {"matching", "missing", "differing", "unverified", "unsupported", "unresolved", "extra", "unknown_difference"} or
                        any(type(value) is not int or value < 0 for value in counts.values())):
                    self.reporting_invalid = True
                    return
            else:
                for key in ("domain", "reason", "phase", "support", "status", "comparison_kind"):
                    value = record.get(key)
                    if value is not None and (not isinstance(value, str) or not re.fullmatch(r"[a-z][a-z0-9_-]{0,63}", value)):
                        self.reporting_invalid = True
                        return
                if kind == "comparison" and (not re.fullmatch(r"v:[0-9]+", str(record["record_id"])) or
                        record["comparison_kind"] not in {"matching", "missing", "differing", "unverified"} or
                        record["support"] not in {"supported", "unsupported"}):
                    self.reporting_invalid = True
                    return
                if kind == "extra_status" and (record["status"] not in {"available", "unavailable", "not_applicable"} or
                        record["count"] is not None and (type(record["count"]) is not int or record["count"] < 0)):
                    self.reporting_invalid = True
                    return
                if "item_id" in record:
                    identity = record["item_id"]
                    if not isinstance(identity, str):
                        self.reporting_invalid = True
                        return
                    if not re.fullmatch(r"opaque:[0-9a-f]{64}", identity):
                        record["item_id"] = item(record["domain"], identity)
            record.pop("kind")
            if kind == "comparison_summary":
                self.comparison = record
            else:
                bucket = {"comparison": self.comparison_records, "extra": self.extra_records,
                          "extra_status": self.extra_status}[kind]
                bucket.append(record)
            return
        if not isinstance(record, dict) or record.get("kind") not in {
                "lifecycle", "operation", "verification", "coverage", "diagnostic", "details_complete", "truncated", "reporting_failed"}:
            self.reporting_invalid = True
            return
        if record["kind"] == "reporting_failed":
            self.reporting_invalid = True
            self.details["status"] = "invalid"
            return
        fields = {
            "lifecycle": {"domain", "item_id", "action", "state", "reason", "changed"},
            "operation": {"record_id", "domain", "item_id", "action", "outcome", "reason"},
            "verification": {"record_id", "domain", "item_id", "predicate", "conformity", "support", "observed_at"},
            "coverage": {"record_id", "domain", "item_id", "disposition", "source_status"},
            "diagnostic": {"record_id", "code", "severity", "phase"},
            "details_complete": set(), "truncated": set(),
        }
        required = fields[record["kind"]] - {"changed"}
        if not required <= set(record) or set(record) - {"kind"} - fields[record["kind"]]:
            self.reporting_invalid = True
            return
        for key, value in record.items():
            if key in {"kind", "domain", "action", "state", "outcome", "predicate", "conformity",
                       "support", "disposition", "source_status", "code", "severity", "phase", "reason"}:
                if value is not None and (not isinstance(value, str) or not re.fullmatch(r"[a-z][a-z0-9_-]{0,63}", value)):
                    self.reporting_invalid = True
                    return
        if "record_id" in record and (not isinstance(record["record_id"], str) or not
                re.fullmatch(r"(?:[vco]:[0-9]+|run|[0-9]+)", record["record_id"])):
            self.reporting_invalid = True
            return
        observed = record.get("observed_at")
        if observed is not None and (not isinstance(observed, str) or not
                re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", observed)):
            self.reporting_invalid = True
            return
        if "domain" in record:
            if not isinstance(record.get("item_id"), str):
                self.reporting_invalid = True
                return
            identity = record["item_id"]
            if not re.fullmatch(r"opaque:[0-9a-f]{64}", identity):
                record["item_id"] = item(record["domain"], identity)
        self.report_count += 1
        if self.report_count > MAX_RECORDS or record["kind"] == "truncated":
            self.details["status"] = "truncated"
            return
        if record["kind"] == "details_complete":
            if self.details["status"] != "truncated":
                self.details["status"] = "complete"
            return
        domain = record.get("domain")
        identity = record.get("item_id")
        if domain == "git-repositories":
            record["item_id"] = self.identities.get(identity, identity)
        if domain == "ssh-identities":
            record["domain"] = "secure-ssh-identities"
        kind = record.pop("kind")
        bucket = {"verification": "verification_records", "coverage": "coverage_records",
                  "operation": "operation_records", "diagnostic": "diagnostics"}.get(kind)
        if bucket:
            self.details[bucket].append(record)
        elif kind == "lifecycle" and record.get("state") not in ("started", "applying", "verifying"):
            self.details["module_outcomes"].append(record)
        if self.on_record:
            self.on_record(kind, record)

    def _drain(self):
        if self.report_fd is None:
            return
        while True:
            try:
                data = os.read(self.report_fd, 65536)
            except BlockingIOError:
                break
            if not data:
                os.close(self.report_fd)
                self.report_fd = None
                if self.report_buffer:
                    self.reporting_invalid = True
                break
            self.report_buffer += data
            while b"\n" in self.report_buffer:
                line, self.report_buffer = self.report_buffer.split(b"\n", 1)
                if len(line) > MAX_LINE:
                    self.reporting_invalid = True
                    continue
                try:
                    self._record(json.loads(line))
                except (ValueError, TypeError, KeyError):
                    self.reporting_invalid = True
            if len(self.report_buffer) > MAX_LINE:
                self.reporting_invalid = True
                self.report_buffer = b""
        if self.reporting_invalid:
            self.details["status"] = "invalid"

    def _collect(self):
        self.unknown_consequences = Path(self.item_state.name, 'external-tool-active.json').exists()
        self.external_lifecycle_cause = None
        if self.unknown_consequences:
            try:
                cause = json.loads(Path(self.item_state.name, 'external-tool-active.json').read_text()).get('cause')
                if cause in {'item_stalled_timeout', 'progress_observation_failed', 'cancelled', 'item_install_failed'}:
                    self.external_lifecycle_cause = cause
            except (OSError, ValueError, TypeError, AttributeError):
                pass
        self.independent_work_completed = getattr(self, 'independent_work_completed', False) or Path(self.item_state.name, 'execution-complete').is_file()
        self.item_state.cleanup()
        self._drain()
        if self.report_fd is not None:
            os.close(self.report_fd)
            self.report_fd = None
        for descriptor, attribute in ((self.signal_fd, "signal_fd"),
                                      (self.verification_fd, "verification_fd")):
            if descriptor is None:
                continue
            os.set_blocking(descriptor, False)
            try:
                data = os.read(descriptor, 4096)
            except BlockingIOError:
                data = b""
            os.close(descriptor)
            setattr(self, attribute, None)
            if attribute == "signal_fd":
                self.mutation_may_have_started |= b"mutation_may_have_started\n" in data
            elif data:
                fields = data.decode("ascii", errors="replace").strip().split("\t")
                if len(fields) == 12 and fields[0] == "v1":
                    try:
                        self.verification = {
                            "status": fields[1], "verdict": fields[2],
                            "selected_count": int(fields[3]), "verified_count": int(fields[4]),
                            "mismatch_count": int(fields[5]), "unverified_count": int(fields[6]),
                            "unresolved_count": int(fields[7]), "warning_count": int(fields[8]),
                            "error_count": int(fields[9]),
                            "bootstrap_warning_count": int(fields[10]),
                            "bootstrap_error_count": int(fields[11]),
                        }
                    except ValueError:
                        pass

    def wait(self):
        while self.process.poll() is None:
            if self.tree is not None and time.monotonic() - self.last_tree_scan >= .5:
                self.tree.scan(); self.last_tree_scan = time.monotonic()
            if self.report_fd is not None:
                select.select([self.report_fd], [], [], .1)
                self._drain()
            else:
                try:
                    self.process.wait(timeout=.1)
                except subprocess.TimeoutExpired:
                    pass
        result = self.process.wait()
        self._collect()
        return result

    def _stop_compare_descendants(self):
        # A stopped shell can leave a reader grandchild that ignored TERM.
        if getattr(self, "mode", None) == "--application-compare":
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def cancel(self):
        was_running = self.process.poll() is None
        if self.tree is not None:
            self.tree.stop()
            if was_running:
                self.process.wait()
                self._collect()
                return 130
        if self.process.poll() is not None:
            self._stop_compare_descendants()
            self._collect()
            return self.process.returncode
        try:
            os.killpg(self.process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            # Drain while stopping: the child may be blocked writing reports.
            import time
            deadline = time.monotonic() + 3
            while self.process.poll() is None and time.monotonic() < deadline:
                if self.report_fd is not None:
                    select.select([self.report_fd], [], [], .1)
                    self._drain()
                else:
                    time.sleep(.05)
            self.process.wait(timeout=max(.01, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.process.wait()
        self._stop_compare_descendants()
        self._collect()
        return 130
