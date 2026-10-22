"""Drain opaque VS Code CLI output; emit only a closed, conservative reason.

No raw output is retained, even in verbose mode. Only the pre-install CLI
failure shape is qualified for independent continuation. Additional/unrecognized
output makes the result unknown rather than guessing its cause or safety.
"""
import sys

MAX_LINE = 4096
RESET_LINES = {
    b"Error while installing extensions: read ECONNRESET",
    b"Error: read ECONNRESET",
    b"read ECONNRESET",
}
PROGRESS_LINES = {b"", b"Installing extensions..."}


class Diagnostic:
    """Bounded incremental reader, also used by the owned CLI supervisor."""
    def __init__(self):
        self.pending = b""
        self.oversized = self.reset = self.unknown = False

    def observe(self, line):
        line = line.removesuffix(b"\r")
        if line in RESET_LINES:
            self.reset = True
        elif line not in PROGRESS_LINES:
            self.unknown = True

    def feed(self, chunk):
        parts = chunk.split(b"\n")
        for index, part in enumerate(parts):
            if not self.oversized:
                if len(self.pending) + len(part) > MAX_LINE:
                    self.pending = b""
                    self.oversized = self.unknown = True
                else:
                    self.pending += part
            if index < len(parts) - 1:
                if not self.oversized:
                    self.observe(self.pending)
                self.pending = b""
                self.oversized = False

    def reason(self):
        if self.pending and not self.oversized:
            self.observe(self.pending)
        return "network_reset" if self.reset and not self.unknown else "unknown"


def classify(stream):
    diagnostic = Diagnostic()
    while True:
        chunk = stream.read(4096)
        if not chunk:
            return diagnostic.reason()
        diagnostic.feed(chunk)


if __name__ == "__main__":
    print("reason:" + classify(sys.stdin.buffer))
