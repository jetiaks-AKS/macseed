"""Fail-closed Execute fence for unconfirmed external-process consequences.

No scheduler or recovery authority. Observers only read this fence; only the
owning mutating Execute records uncertainty. There is no automatic clearing.
"""
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'apps/adapters'))
from homebrew_lifecycle import state_directory_fd, read_state, journal


def directory():
    return Path.home().resolve() / 'Library/Application Support/Macseed/ExternalProcesses'


def pending():
    try:
        descriptor = state_directory_fd(directory())
        try:
            read_state(descriptor)
            return True
        finally:
            os.close(descriptor)
    except FileNotFoundError:
        return False
    except (OSError, ValueError):
        return True


def retain():
    # An earlier record is already sufficient and is never overwritten.
    if pending():
        return
    journal(directory(), {'contract': 1, 'state': 'unknown_consequences',
                          'tool': 'external_process', 'cause': 'external_execution_unconfirmed'})


if __name__ == '__main__':
    sys.exit(0 if pending() else 1)
