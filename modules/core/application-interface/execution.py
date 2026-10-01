"""Owned, non-interactive production subprocess for future Core execution."""

import os
import signal
import subprocess


class OwnedBootstrap:
    def __init__(self, root, environment):
        read_fd, write_fd = os.pipe()
        verification_read, verification_write = os.pipe()
        child_env = dict(environment)
        child_env.update(MACSEED_APPLICATION_EXECUTION="true",
                         MACSEED_EXECUTION_SIGNAL_FD=str(write_fd),
                         MACSEED_VERIFICATION_FD=str(verification_write))
        try:
            self.process = subprocess.Popen(
                ["./bootstrap.sh", "--bootstrap"], cwd=root, env=child_env,
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, start_new_session=True,
                pass_fds=(write_fd, verification_write))
        except BaseException:
            os.close(read_fd)
            os.close(write_fd)
            os.close(verification_read)
            os.close(verification_write)
            raise
        os.close(write_fd)
        os.close(verification_write)
        self.signal_fd = read_fd
        self.verification_fd = verification_read
        self.mutation_may_have_started = False
        self.verification = None

    def _collect(self):
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
        result = self.process.wait()
        self._collect()
        return result

    def cancel(self):
        if self.process.poll() is not None:
            self._collect()
            return self.process.returncode
        try:
            os.killpg(self.process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.process.wait()
        self._collect()
        return 130
