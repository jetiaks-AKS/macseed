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


def classify(stream):
    pending = b""
    oversized = False
    reset = False
    unknown = False

    def observe(line):
        nonlocal reset, unknown
        line = line.removesuffix(b"\r")
        if line in RESET_LINES:
            reset = True
        elif line not in PROGRESS_LINES:
            unknown = True

    while True:
        chunk = stream.read(4096)
        if not chunk:
            break
        parts = chunk.split(b"\n")
        for index, part in enumerate(parts):
            if not oversized:
                if len(pending) + len(part) > MAX_LINE:
                    pending = b""
                    oversized = unknown = True
                else:
                    pending += part
            if index < len(parts) - 1:
                if not oversized:
                    observe(pending)
                pending = b""
                oversized = False
    if pending and not oversized:
        observe(pending)
    return "network_reset" if reset and not unknown else "unknown"


if __name__ == "__main__":
    print("reason:" + classify(sys.stdin.buffer))
