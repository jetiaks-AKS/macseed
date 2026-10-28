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
    from observation import read, ObservationError, PHASE_SECONDS
    try:
        result = read(command, PHASE_SECONDS, cwd=root, env=environment, progress=progress)
    except ObservationError:
        return 2
    if output is not None:
        output.write(result.stdout)
    return result.returncode


def destination(path, replacement_sha256=None):
    if (not isinstance(path, str) or not path.startswith('/') or
            any(ord(c) < 32 or ord(c) == 127 for c in path)):
        raise CaptureError('invalid_destination')
    target = Path(path)
    parent = target.parent
    if (target.suffix != '.mbt' or (replacement_sha256 is None and target.exists()) or target.is_symlink() or
            not parent.is_dir() or parent.is_symlink() or str(parent.resolve()) != str(parent) or
            parent.stat().st_uid != os.getuid()):
        raise CaptureError('invalid_destination')
    if replacement_sha256 is not None:
        try:
            bundle.check_replacement(target, replacement_sha256)
        except (OSError, bundle.Invalid) as exc:
            raise CaptureError('invalid_destination') from exc
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
            set(whole) - set(domains) or set(selection['items']) - set(bundle.SELECTABLE_ITEMS) or
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


def blueprint_data(chosen):
    flags = {name: name in chosen for name in bundle.CATEGORY_FLAGS}
    raw = '[categories]\n' + ''.join(f'{key}="{str(value).lower()}"\n' for key, value in sorted(flags.items()))
    raw += ''.join('\n[' + key + ']\n' + ''.join(value + '\n' for value in chosen.get(key, [])) for key in bundle.SELECTABLE_ITEMS if key in bundle.ITEMS or chosen.get(key))
    bundle.parse_blueprint(raw.encode())
    return raw.encode()


def blueprint(stage, chosen):
    bundle.write_file(stage / 'blueprint.conf', blueprint_data(chosen))


def application_scope(stage, chosen, rows, requested):
    """Resolve the same bounded precedence before confirmation and Execute binding."""
    if not chosen.get('homebrew-casks') or not chosen.get('app-store'):
        return chosen, None, []
    path = stage / 'generated/homebrew-casks.json'
    capabilities = bundle.cask_capabilities(json.loads(bundle.checked_file(path))) if path.exists() or path.is_symlink() else {'contract': 1, 'casks': {}}
    _, pairs, _ = bundle.application_precedence(blueprint_data(chosen), capabilities)
    if not pairs:
        return chosen, None, []
    ids = {row['domain']: {entry['_source']: entry['item_id'] for entry in row['items']}
           for row in rows if row['domain'] in ('app-store', 'homebrew-casks')}
    effective_chosen = dict(chosen)
    remaining = [value for value in chosen['app-store'] if value not in pairs]
    if remaining:
        effective_chosen['app-store'] = remaining
    else:
        del effective_chosen['app-store']
    effective = {**requested, 'categories': [domain for domain in requested['categories'] if domain != 'app-store'],
                 'items': dict(requested['items'])}
    effective['items'].pop('app-store', None)
    if remaining:
        effective['items']['app-store'] = sorted(ids['app-store'][value] for value in remaining)
    duplicates = [{'app_store_item_id': ids['app-store'][app_id], 'cask_item_id': ids['homebrew-casks'][token]}
                  for app_id, token in sorted(pairs.items())]
    return effective_chosen, effective, duplicates


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
    expected = set(bundle.SELECTABLE_ITEMS) | set(bundle.CATEGORIES)
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


def included_settings(stage, row):
    if row['status'] != 'present':
        return []
    root = Path(__file__).resolve().parents[3]
    path = stage / 'generated' / bundle.CATEGORIES[row['domain']]
    projection = subprocess.run(
        ['bash', '-c', 'source modules/settings/macos/records.sh; macos_included_settings "$1" "$2"',
         'capture-settings', str(path), row['domain'][len('macos-'):]],
        cwd=root, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        timeout=10, check=False)
    if projection.returncode != 0:
        raise CaptureError('capture_inventory_invalid')
    return [dict(zip(('id', 'label'), line.split('\t')))
            for line in projection.stdout.decode('utf-8').splitlines()]


def prepared(stage, rows, secure, selection):
    chosen, identities, canonical = selection_for(selection, rows, secure) if selection is not None else ({}, [], None)
    chosen, effective, duplicates = application_scope(stage, chosen, rows, canonical)
    if selection is not None:
        raw = blueprint_data(chosen)
        try:
            files = bundle.staged_payload(stage, raw)
        except (bundle.Invalid, OSError) as exc:
            raise CaptureError('capture_inventory_invalid') from exc
        try:
            bundle.validate_workspace(files, home=os.environ['HOME'])
        except bundle.WorkspaceSelectionInvalid as exc:
            raise CaptureError(exc.code) from exc
        except (bundle.Invalid, OSError) as exc:
            raise CaptureError('invalid_workspace_selection') from exc
    # Hash private staged inputs; neither input values nor their per-file hashes are public.
    fingerprints = {}
    for path in sorted((stage / 'generated').rglob('*')):
        if path.is_symlink():
            raise CaptureError('capture_inventory_invalid')
        if path.is_file():
            fingerprints[str(path.relative_to(stage))] = bundle.digest(bundle.checked_file(path))
    binding = {'schema': 1, 'inputs': fingerprints, 'inventory': rows, 'secure': secure, 'selection': canonical}
    if duplicates:
        binding.update(effective_selection=effective, application_duplicates=duplicates)
    prepared_id = bundle.digest(json.dumps(binding, sort_keys=True, separators=(',', ':')).encode())
    public_rows = []
    for row in rows:
        public_row = {**row, 'items': [{k: v for k, v in entry.items() if not k.startswith('_')} for entry in row['items']]}
        if row['domain'].startswith('macos-'):
            public_row['included_settings'] = included_settings(stage, row)
        public_rows.append(public_row)
    public_secure = {**secure, 'items': [{k: v for k, v in entry.items() if not k.startswith('_')} for entry in secure['items']]}
    result = {'prepared_capture_id': prepared_id, 'inventory': public_rows, 'secure_identities': public_secure,
              'selection': canonical, 'summary': {'selected_domains': len(chosen),
               'selected_items': sum(len(values) for values in chosen.values()), 'secure_identity_count': len(identities)}}
    if duplicates:
        result.update(effective_selection=effective, application_duplicates=duplicates)
    return result, chosen, identities


def capture(root, operation, parameters, channel, event):
    from secret_input import PrivateTemporaryDirectory, SecureError
    target = destination(parameters['destination'], parameters.get('replacement_sha256')) if operation == 'capture_execute' else None
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
            preview = stage / '.capture-preview.conf'
            bundle.write_file(preview, bundle.capture_preview(stage, os.environ['HOME']))
            if run(root, ['./bootstrap.sh', '--dry-run'], dict(environment, BLUEPRINT_FILE=str(preview))) > 1:
                raise CaptureError('capture_validation_failed')
            event('phase_completed', {'phase': 'validation'})
            if identities:
                selected = stage / 'secure-selection.json'
                bundle.write_file(selected, json.dumps(identities).encode())
                export_secure(root, stage / 'secure.age', selected, channel, parameters['_operation_id'], event)
            else:
                event('secure_packaging', {'status': 'not_selected'})
            destination(parameters['destination'], parameters.get('replacement_sha256'))
            event('phase_started', {'phase': 'bundle_creation'})
            previous = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM})
            try:
                # Execute has freshly recomputed and checked the effective scope.
                # Packing must not make another optional network-dependent decision.
                bundle.pack(stage, target, os.environ['HOME'], replacement_sha256=parameters.get('replacement_sha256'),
                            apply_precedence=False)
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


def workspace_row(destination_path, source, status, reason):
    entries = []
    if status == 'present':
        try:
            path = Path(source)
            if not path.exists() and not path.is_symlink():
                status, reason = 'unavailable', 'no_supported_items'
            else:
                contract = bundle.workspace_contract()
                value = contract.objects(bundle.checked_file(path, contract.MAX_BYTES))
                for row in contract.rows(value['items']):
                    identity = contract.identity('workspace', contract.portable(row['path']))
                    if identity != row['item_id']:
                        raise ValueError()
                    entries.append(dict(item_id=identity, label=contract.workspace_label(row['path']), _source=identity))
        except (OSError, ValueError, KeyError, bundle.Invalid):
            entries = []
            status, reason = 'observation_error', 'inventory_invalid'
    value = dict(domain='vscode-workspaces', status=status, reason=reason or None,
                 selection_mode='items', items=entries)
    with open(destination_path, 'a', encoding='utf-8') as output:
        os.chmod(destination_path, 0o600)
        output.write(json.dumps(value, sort_keys=True) + '\n')


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
        topology = domain == 'git-repositories' and re.fullmatch(r'checkout-[0-9a-f]{64}', source)
        identity = source if topology else item(domain, source)
        # Repository names and private paths remain index-addressable, without remote URLs.
        label = (source if re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_. -]{0,79}', source) else f'Repository {index}') if domain == 'git-repositories' else identity
        if topology:
            label = labels[index - 1] if re.fullmatch(r'[\w .+-]{1,80}', labels[index - 1]) else f'Repository {index}'
        if domain == 'app-store' and re.fullmatch(r'[\w .+()&-]{1,160}', labels[index - 1]):
            label = labels[index - 1]
        entries.append({'item_id': identity, 'label': label, '_source': source})
    value = {'domain': domain, 'status': status, 'reason': reason or None,
             'selection_mode': 'items' if domain in bundle.SELECTABLE_ITEMS else 'category', 'items': entries}
    with open(destination_path, 'a', encoding='utf-8') as output:
        os.chmod(destination_path, 0o600)
        output.write(json.dumps(value, sort_keys=True) + '\n')


if __name__ == '__main__':
    if len(sys.argv) == 6 and sys.argv[1] == '--workspace-row':
        workspace_row(*sys.argv[2:])
    elif len(sys.argv) == 3 and sys.argv[1] == '--row':
        row(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == '--path':
        print((bundle.SELECTABLE_ITEMS | bundle.CATEGORIES)[sys.argv[2]])
    else:
        sys.exit(2)
