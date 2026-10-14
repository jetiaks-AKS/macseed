"""Disposable, bounded process tree; no installation or user-state access."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

mode, directory = sys.argv[1:]
root = Path(directory)
if mode == 'leaf':
    if (root / 'ignore').exists():
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    (root / 'leaf-ready').write_text(str(os.getpid()))
    time.sleep(30)
    sys.exit(0)
child = None
if mode != 'plain':
    child = subprocess.Popen([sys.executable, '-B', __file__, 'leaf', directory],
                             start_new_session=mode in ('detached', 'unseen', 'denied'))
    deadline = time.monotonic() + 5
    while not (root / 'leaf-ready').exists():
        if time.monotonic() > deadline:
            child.kill(); child.wait(); raise RuntimeError('child readiness timeout')
        time.sleep(.01)
(root / 'ready.tmp').write_text(json.dumps({'root': os.getpid(), 'child': child.pid if child else None}))
(root / 'ready.tmp').replace(root / 'ready')
# Parent waits/reaps ordinary children, but intentionally leaves denied/unseen
# children for the controller's independent, identity-checked cleanup.
def terminate(*_):
    if child and mode not in ('denied', 'unseen'):
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            return
    sys.exit(0)
signal.signal(signal.SIGTERM, terminate)
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    if mode == 'unseen' and (root / 'release').exists():
        sys.exit(0)
    if child:
        child.poll()
    time.sleep(.02)
