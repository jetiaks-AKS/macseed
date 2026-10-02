"""Structured orchestration of production Discovery, Blueprint and Bundle Capture."""
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'bundle'))
import bundle
from reporting import item, opaque
from secure import terminate, export_secure

MAX_ITEMS = 2048
MAX_INVENTORY = 1024 * 1024


class CaptureError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def run(root, command, environment, output=None, progress=None):
    child = subprocess.Popen(command, cwd=root, env=environment, stdin=subprocess.DEVNULL,
                             stdout=output if output is not None else subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        while child.poll() is None:
            if progress is not None:
                progress()
            try:
                child.wait(timeout=.1)
            except subprocess.TimeoutExpired:
                pass
        if progress is not None:
            progress()
        return child.returncode
    finally:
        terminate(child)


def destination(path):
    if (not isinstance(path, str) or not path.startswith('/') or
            any(ord(c) < 32 or ord(c) == 127 for c in path)):
        raise CaptureError('invalid_destination')
    target = Path(path)
    parent = target.parent
    if (target.suffix != '.mbt' or target.exists() or target.is_symlink() or
            not parent.is_dir() or parent.is_symlink() or str(parent.resolve()) != str(parent) or
            parent.stat().st_uid != os.getuid()):
        raise CaptureError('invalid_destination')
    return target


def selection_for(selection, rows, secure):
    # Whole domains and explicit item subsets map directly to Blueprint's scope.
    if (not isinstance(selection, dict) or set(selection) != {'categories', 'items', 'secure_identities'} or
            not isinstance(selection['categories'], list) or not isinstance(selection['items'], dict) or
            not isinstance(selection['secure_identities'], list)):
        raise CaptureError('invalid_selection')
    domains = {row['domain']: row for row in rows}
    whole = selection['categories']
    identities = selection['secure_identities']
    if (not all(isinstance(x, str) for x in whole + identities) or
            len(whole) != len(set(whole)) or len(identities) != len(set(identities)) or
            set(whole) - set(domains) or set(selection['items']) - set(bundle.ITEMS) or
            set(whole) & set(selection['items'])):
        raise CaptureError('invalid_selection')
    chosen = {}
    for domain in sorted(set(whole) | set(selection['items'])):
        row = domains[domain]
        if row['status'] != 'present':
            raise CaptureError('capture_source_unavailable')
        available = {entry['item_id']: entry['_source'] for entry in row['items']}
        wanted = list(available) if domain in whole else selection['items'][domain]
        if (not isinstance(wanted, list) or not all(isinstance(x, str) for x in wanted) or
                len(wanted) != len(set(wanted)) or set(wanted) - set(available)):
            raise CaptureError('invalid_selection')
        chosen[domain] = sorted(available[x] for x in wanted)
    candidates = {entry['item_id']: entry for entry in secure.get('items', [])}
    if set(identities) - set(candidates) or (identities and secure['status'] != 'present'):
        raise CaptureError('invalid_secure_selection')
    canonical = {'categories': sorted(whole), 'items': {key: sorted(value) for key, value in sorted(selection['items'].items())},
                 'secure_identities': sorted(identities)}
    return chosen, [candidates[x] for x in sorted(identities)], canonical


def blueprint(stage, chosen):
    flags = {name: name in chosen for name in bundle.CATEGORY_FLAGS}
    raw = '[categories]\n' + ''.join(f'{key}="{str(value).lower()}"\n' for key, value in sorted(flags.items()))
    raw += ''.join('\n[' + key + ']\n' + ''.join(value + '\n' for value in chosen.get(key, [])) for key in bundle.ITEMS)
    bundle.parse_blueprint(raw.encode())
    bundle.write_file(stage / 'blueprint.conf', raw.encode())


def scan(root, stage, event):
    generated = stage / 'generated'
    generated.mkdir(mode=0o700)
    inventory = stage / 'inventory.jsonl'
    environment = dict(os.environ, BLUEPRINT_FILE=str(stage / 'blueprint.conf'),
                       BLUEPRINT_GENERATED_DIR=str(generated), MACSEED_APPLICATION_EXECUTION='true',
                       MACSEED_APPLICATION_CAPTURE='true', MACSEED_CAPTURE_INVENTORY=str(inventory),
                       HOMEBREW_NO_AUTO_UPDATE='1')
    for key in ('BUNDLE_RESTORE_ACTIVE', 'BUNDLE_RESTORE_PREVIEW', 'SSH_SNAPSHOT_FILE', 'ZSH_SNAPSHOT_FILE',
                'MACSEED_REPORT_FD', 'MACSEED_EXECUTION_SIGNAL_FD', 'MACSEED_VERIFICATION_FD'):
        environment.pop(key, None)
    event('phase_started', {'phase': 'discovery'})
    emitted = 0
    def progress():
        nonlocal emitted
        if not inventory.is_file():
            return
        if inventory.stat().st_size > MAX_INVENTORY:
            raise CaptureError('capture_inventory_invalid')
        lines = inventory.read_bytes().split(b'\n')[:-1]
        for line in lines[emitted:]:
            row = json.loads(line)
            event('capture_category', {key: row[key] for key in ('domain', 'status', 'reason')})
        emitted = len(lines)
    status = run(root, ['./bootstrap.sh', '--discover'], environment, progress=progress)
    if status > 1 or not inventory.is_file() or inventory.stat().st_size > MAX_INVENTORY:
        raise CaptureError('capture_discovery_failed')
    rows = [json.loads(line) for line in inventory.read_text().splitlines()]
    expected = set(bundle.ITEMS) | set(bundle.CATEGORIES)
    if len(rows) != len(expected) or {row['domain'] for row in rows} != expected:
        raise CaptureError('capture_inventory_invalid')
    event('phase_completed', {'phase': 'discovery'})
    secure_file = stage / 'identities.json'
    with secure_file.open('xb') as output:
        os.fchmod(output.fileno(), 0o600)
        status = run(root, ['./scripts/ssh-identity-migrate.sh', 'application-list'], environment, output)
    if status != 0:
        secure = {'status': 'observation_error', 'reason': 'secure_inventory_failed', 'items': []}
    elif secure_file.stat().st_size > MAX_INVENTORY:
        raise CaptureError('capture_inventory_invalid')
    else:
        secure = json.loads(secure_file.read_bytes())
    return rows, secure, environment


def prepared(stage, rows, secure, selection):
    chosen, identities, canonical = selection_for(selection, rows, secure) if selection is not None else ({}, [], None)
    # Hash private staged inputs; neither input values nor their per-file hashes are public.
    fingerprints = {}
    for path in sorted((stage / 'generated').rglob('*')):
        if path.is_symlink():
            raise CaptureError('capture_inventory_invalid')
        if path.is_file():
            fingerprints[str(path.relative_to(stage))] = bundle.digest(bundle.checked_file(path))
    binding = {'schema': 1, 'inputs': fingerprints, 'inventory': rows, 'secure': secure, 'selection': canonical}
    prepared_id = bundle.digest(json.dumps(binding, sort_keys=True, separators=(',', ':')).encode())
    public_rows = []
    for row in rows:
        public_rows.append({**row, 'items': [{k: v for k, v in entry.items() if not k.startswith('_')} for entry in row['items']]})
    public_secure = {**secure, 'items': [{k: v for k, v in entry.items() if not k.startswith('_')} for entry in secure['items']]}
    result = {'prepared_capture_id': prepared_id, 'inventory': public_rows, 'secure_identities': public_secure,
              'selection': canonical, 'summary': {'selected_domains': len(chosen),
               'selected_items': sum(len(values) for values in chosen.values()), 'secure_identity_count': len(identities)}}
    return result, chosen, identities


def capture(root, operation, parameters, channel, event):
    from secret_input import PrivateTemporaryDirectory, SecureError
    target = destination(parameters['destination']) if operation == 'capture_execute' else None
    published = False
    try:
        with PrivateTemporaryDirectory(prefix='macseed-capture-', dir='/private/tmp') as temporary:
            stage = Path(temporary)
            os.chmod(stage, 0o700)
            rows, secure, environment = scan(root, stage, event)
            result, chosen, identities = prepared(stage, rows, secure, parameters['selection'])
            if operation == 'capture_prepare':
                event('result', result)
                event('completed')
                return 0
            event('phase_started', {'phase': 'validation'})
            if parameters['expected_prepared_capture_id'] != result['prepared_capture_id']:
                raise CaptureError('stale_prepared_capture')
            if identities and channel is None:
                raise CaptureError('secure_bridge_required')
            if identities and not __import__('shutil').which('age'):
                raise CaptureError('age_unavailable')
            blueprint(stage, chosen)
            # The selected Blueprint/input validators and portability checks remain production-owned.
            if run(root, ['./bootstrap.sh', '--dry-run'], environment) > 1:
                raise CaptureError('capture_validation_failed')
            files = {name: bundle.checked_file(stage / name) for name in bundle.required_paths(bundle.checked_file(stage / 'blueprint.conf'))}
            bundle.selected_payload(files, bundle.checked_file(stage / 'blueprint.conf'))
            bundle.portable_paths(files, os.environ['HOME'])
            event('phase_completed', {'phase': 'validation'})
            if identities:
                selected = stage / 'secure-selection.json'
                bundle.write_file(selected, json.dumps(identities).encode())
                export_secure(root, stage / 'secure.age', selected, channel, parameters['_operation_id'], event)
            else:
                event('secure_packaging', {'status': 'not_selected'})
            destination(parameters['destination'])
            event('phase_started', {'phase': 'bundle_creation'})
            previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
            try:
                bundle.pack(stage, target, os.environ['HOME'])
                published = True
                result = {'publication_occurred': True, 'destination': str(target),
                          'bundle': bundle.inspect_bundle(target, os.environ['HOME']),
                          'prepared_capture_id': result['prepared_capture_id']}
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, previous)
            event('phase_completed', {'phase': 'bundle_creation'})
            event('result', result)
            event('completed')
            return 0
    except CaptureError as exc:
        event('failed', {'code': exc.code, 'publication_occurred': published})
        return 2
    except SecureError as exc:
        event('failed', {'code': exc.code, 'publication_occurred': published})
        return 130 if exc.code == 'secure_cancelled' else 2
    except BaseException as exc:
        if exc.__class__.__name__ == 'Cancelled' or isinstance(exc, KeyboardInterrupt):
            event('failed', {'code': 'cancelled', 'publication_occurred': published})
            return 130
        event('failed', {'code': 'capture_failed', 'publication_occurred': published})
        return 2


def row(destination_path):
    fields = sys.stdin.buffer.read(MAX_INVENTORY + 1).decode().split('\0')
    if fields[-1] != '' or len(fields) < 4:
        raise ValueError('invalid collector input')
    domain, status, reason, *pairs = fields[:-1]
    sources, labels = pairs[::2], pairs[1::2]
    if len(pairs) % 2 or len(sources) > MAX_ITEMS or len(sources) != len(set(sources)):
        raise ValueError('oversized or duplicate inventory')
    entries = []
    for index, source in enumerate(sources, 1):
        identity = item(domain, source)
        # Repository names and private paths remain index-addressable, without remote URLs.
        label = (source if re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_. -]{0,79}', source) else f'Repository {index}') if domain == 'git-repositories' else identity
        if domain == 'app-store' and re.fullmatch(r'[\w .+()&-]{1,160}', labels[index - 1]):
            label = labels[index - 1]
        entries.append({'item_id': identity, 'label': label, '_source': source})
    value = {'domain': domain, 'status': status, 'reason': reason or None,
             'selection_mode': 'items' if domain in bundle.ITEMS else 'category', 'items': entries}
    with open(destination_path, 'a', encoding='utf-8') as output:
        os.chmod(destination_path, 0o600)
        output.write(json.dumps(value, sort_keys=True) + '\n')


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--row':
        row(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == '--path':
        print((bundle.ITEMS | bundle.CATEGORIES)[sys.argv[2]])
    else:
        sys.exit(2)
