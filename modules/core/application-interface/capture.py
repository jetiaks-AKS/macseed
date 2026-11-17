"""Structured orchestration of production Discovery, Blueprint and Bundle Capture."""
import hashlib
import importlib.util
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
from age_runtime import DESKTOP_BUNDLE, executable as age_executable
from external_sources import ExternalSourceError, operation_paths, read_pair as external_pair

_spec = importlib.util.spec_from_file_location('shell_capture', bundle.ROOT / 'modules/shell/capture.py')
functions = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(functions)

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
            set(whole) - set(domains) or set(selection['items']) - set(bundle.ITEM_SELECTION) or
            set(whole) & set(selection['items'])):
        raise CaptureError('invalid_selection')
    chosen = {}
    for domain in sorted(set(whole) | set(selection['items'])):
        row = domains[domain]
        if domain == 'shell-zsh' and domain in whole:
            # Category selection retains its legacy meaning. Functions require
            # explicit B1 IDs; an old client cannot opt into a new capability.
            row = row.get('_legacy', row)
        if row['status'] != 'present':
            raise CaptureError('capture_source_unavailable')
        available = {entry['item_id']: entry['_source'] for entry in row['items']}
        wanted = list(available) if domain in whole else selection['items'][domain]
        if (not isinstance(wanted, list) or not all(isinstance(x, str) for x in wanted) or
                len(wanted) != len(set(wanted)) or set(wanted) - set(available)):
            raise CaptureError('invalid_selection')
        if domain not in ('ssh-configuration', 'shell-zsh') or row['selection_mode'] != 'items' or wanted:
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
            if row['domain'] != 'shell-zsh':
                event('capture_category', {key: row[key] for key in ('domain', 'status', 'reason')})
        emitted = len(lines)
    status = run(root, ['./bootstrap.sh', '--discover'], environment, progress=progress)
    if status > 1 or not inventory.is_file() or inventory.stat().st_size > MAX_INVENTORY:
        raise CaptureError('capture_discovery_failed')
    rows = [json.loads(line) for line in inventory.read_text().splitlines()]
    expected = set(bundle.SELECTABLE_ITEMS) | set(bundle.CATEGORIES)
    if len(rows) != len(expected) or {row['domain'] for row in rows} != expected:
        raise CaptureError('capture_inventory_invalid')
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


def external_inventory(root, stage, paths):
    request = stage / 'external-request.json'
    output = stage / 'external-result.json'
    bundle.write_file(request, json.dumps(paths, ensure_ascii=False).encode())
    with output.open('xb') as stream:
        os.fchmod(stream.fileno(), 0o600)
        status = run(root, ['./scripts/ssh-identity-migrate.sh', 'application-external-list', '--sources', str(request)], os.environ, stream)
    if status != 0 or output.stat().st_size > MAX_INVENTORY:
        raise CaptureError('external_identity_pair_invalid')
    value = json.loads(output.read_bytes())
    if 'error' in value:
        allowed = {'external_identity_unsafe', 'external_identity_name_invalid', 'external_identity_pair_missing',
                   'external_identity_pair_invalid', 'external_identity_changed', 'external_identity_duplicate', 'external_identity_invalid_request'}
        raise CaptureError(value['error'] if value['error'] in allowed else 'external_identity_pair_invalid')
    return value['items']


def add_external(secure, entries):
    if secure['status'] == 'observation_error':
        raise CaptureError('secure_inventory_failed')
    combined = secure['items'] + entries
    if (len(combined) > 32 or len({e['label'].casefold() for e in combined}) != len(combined)
            or len({e['fingerprint'] for e in combined}) != len(combined)):
        raise CaptureError('external_identity_duplicate')
    return {'status': 'present', 'reason': None, 'items': combined}


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


def functional_domain_count(chosen, scripts, rows):
    # Shell remains one physical Core module. File consent selects a separate
    # functional domain; alias definitions and saved files are distinct objects.
    whole_shell = any(row['domain'] == 'shell-zsh' and row.get('_legacy', row)['selection_mode'] == 'category' for row in rows)
    return sum(domain != 'shell-zsh' or bool(items) or whole_shell for domain, items in chosen.items()) + bool(scripts)


def typed_selection(selection, rows):
    wanted = (selection or {}).get('items', {}).get('shell-zsh', [])
    legacy = next(row for row in rows if row['domain'] == 'shell-zsh')
    legacy_ids = {row['item_id'] for row in legacy.get('_legacy', legacy)['items']}
    return wanted if any(functions.function_id(key) or key not in legacy_ids for key in wanted) else []


def prepared(stage, rows, secure, selection, private=None, shell_script_selection=None, shell_script_policy=None,
             function_observation=None):
    item_selection = selection.get('items') if isinstance(selection, dict) else None
    shell_selection = item_selection.get('shell-zsh') if isinstance(item_selection, dict) else None
    requested_functions = [key for key in shell_selection if functions.function_id(key)] if isinstance(shell_selection, list) else []
    if requested_functions and (function_observation is None or function_observation.snapshot is None or
            not set(requested_functions) <= {row['id'] for row in function_observation.snapshot._value['items']}):
        raise CaptureError('capture_functions_unavailable')
    chosen, identities, canonical = selection_for(selection, rows, secure) if selection is not None else ({}, [], None)
    typed_ids = typed_selection(canonical, rows)
    if typed_ids:
        if (function_observation is None or function_observation.snapshot is None or
                not set(typed_ids) <= {row['id'] for row in function_observation.snapshot._value['items']}):
            raise CaptureError('capture_source_unavailable')
        chosen['shell-zsh'] = sorted(typed_ids)
    chosen, effective, duplicates = application_scope(stage, chosen, rows, canonical)
    shell_scripts, shell_observation, shell_candidates = [], None, []
    selected_script_count = 0
    shell = None
    shell_path = stage / 'generated/shell/zshrc.snapshot'
    if (shell_script_selection and shell_path.is_file()) or any(row['domain'] == 'shell-zsh' and row.get('_legacy', row)['status'] == 'present' for row in rows):
        shell = bundle.shell_load(shell_path)
        if shell is not None and shell['version'] in (3, 4, 5):
            shell_candidates = bundle.shell_contract().recovery_contract().selection_candidates(shell, os.environ['HOME'], policy=shell_script_policy or 'opaque-file-v5')
    if shell_script_selection and shell_script_policy in ('opaque-file-v4', 'opaque-file-v5'):
        if selection is None or not set(shell_script_selection) <= {row['id'] for row in shell_candidates}:
            raise CaptureError('invalid_script_consent')
        chosen.setdefault('shell-zsh', [])
        selected_script_count = len(set(shell_script_selection))
    if selection is not None:
        raw = blueprint_data(chosen)
        try:
            if typed_ids:
                # The legacy stage remains intact for legacy selection and its
                # consent policies. Only the explicit typed branch replaces it.
                scripts = []
                if shell_script_selection:
                    if shell is None or shell_script_policy != 'opaque-file-v5':
                        raise CaptureError('invalid_script_consent')
                    recovery = bundle.shell_contract().recovery_contract()
                    shell_scripts = recovery.script_candidates(shell, os.environ['HOME'], policy=shell_script_policy)
                    shell_observation = recovery.sources.dependency_states(shell, os.environ['HOME'], transfer=True)
                    scripts = recovery.authorize_capture(shell, os.environ['HOME'], shell_script_selection,
                        shell_observation, shell_script_policy)['scripts']
                typed, payloads = function_observation.selected(typed_ids, scripts)
                if private is not None:
                    private['typed_shell'] = (typed, payloads)
                files = bundle.staged_payload(stage, blueprint_data({k: v for k, v in chosen.items() if k != 'shell-zsh'}))
                files.update(payloads)
                files.update({'blueprint.conf': raw, functions.state.SNAPSHOT: typed})
                bundle.validate_shell(files)
            else:
                files = bundle.staged_payload(stage, raw)
            if chosen.get('ssh-configuration'):
                bundle.ssh_contract().select_snapshot(files['generated/ssh/config.snapshot'], chosen['ssh-configuration'])
            # Legacy whole-file snapshots have no alias/script selection.
            # Their existing staged-payload and Bundle validators still apply.
            if 'shell-zsh' in chosen and shell is not None and not typed_ids:
                contract = bundle.shell_contract()
                selected_shell = (shell if shell_script_selection and shell_script_policy in ('opaque-file-v4', 'opaque-file-v5') else
                    contract.snapshot(contract.select_snapshot(files['generated/shell/zshrc.snapshot'], chosen['shell-zsh'])))
                if selected_shell['version'] in (3, 4, 5):
                    shell_scripts = contract.recovery_contract().script_candidates(selected_shell, os.environ['HOME'], policy=shell_script_policy)
                    shell_observation = contract.source_contract().dependency_states(selected_shell, os.environ['HOME'], transfer=shell_script_policy == 'opaque-file-v5')
        except (bundle.Invalid, OSError, ValueError) as exc:
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
    if typed_ids:
        binding['shell_functions'] = function_observation.binding
    if shell_observation is not None:
        binding['shell_dependencies'] = shell_observation
        if private is not None:
            private['shell_dependencies'] = shell_observation
    if shell_script_selection is not None:
        if not set(shell_script_selection) <= {row['id'] for row in shell_scripts}:
            raise CaptureError('invalid_script_consent')
        binding['shell_script_selection'] = sorted(shell_script_selection)
    if shell_script_policy is not None:
        binding['shell_script_policy'] = shell_script_policy
    if duplicates:
        binding.update(effective_selection=effective, application_duplicates=duplicates)
    prepared_id = bundle.digest(json.dumps(binding, sort_keys=True, separators=(',', ':')).encode())
    public_rows = []
    for row in rows:
        public_row = {**{k: v for k, v in row.items() if not k.startswith('_')},
                      'items': [{k: v for k, v in entry.items() if not k.startswith('_')} for entry in row['items']]}
        if row['domain'].startswith('macos-'):
            public_row['included_settings'] = included_settings(stage, row)
        public_rows.append(public_row)
    public_secure = {**secure, 'items': [{k: v for k, v in entry.items() if not k.startswith('_')} for entry in secure['items']]}
    result = {'prepared_capture_id': prepared_id, 'inventory': public_rows, 'secure_identities': public_secure,
              'selection': canonical, 'summary': {'selected_domains': functional_domain_count(chosen, shell_script_selection, rows),
               'selected_items': sum(len(values) for values in chosen.values()) + selected_script_count, 'secure_identity_count': len(identities)}}
    if shell_scripts:
        result['shell_scripts'] = shell_scripts
    result['shell_script_policies'] = ['opaque-file-v4', 'opaque-file-v5']
    if shell_candidates:
        result['shell_script_candidates'] = shell_candidates
    if shell_script_policy is not None:
        result['shell_script_policy'] = shell_script_policy
        result['shell_script_selection'] = sorted(shell_script_selection or [])
    if duplicates:
        result.update(effective_selection=effective, application_duplicates=duplicates)
    if function_observation is not None:
        result['shell_functions'] = function_observation.public
    return result, chosen, identities


def capture(root, operation, parameters, channel, event):
    from secret_input import PrivateTemporaryDirectory, SecureError
    if operation == 'capture_script_inspect':
        try:
            recovery = bundle.shell_contract().recovery_contract()
            home = os.environ['HOME']
            value = recovery.capture(home, allow_empty=bool(parameters.get('shell_script_paths')))
            paths = recovery.manual_paths(value, home, parameters.get('shell_script_paths', []))
            candidates = recovery.selection_candidates(value, home, paths, parameters.get('shell_script_policy'))
            added = [row for row in candidates if row['path'] in paths]
            if len(added) != len(paths):
                states = recovery.sources.dependency_states(value, home, paths, transfer=parameters.get('shell_script_policy') == 'opaque-file-v5')
                limit = 'script_count_limit' if parameters.get('shell_script_policy') == 'opaque-file-v5' else 'script_limit'
                raise CaptureError(limit if all(states[path][0] == 'ready' for path in paths)
                                   else 'script_observation_failed')
            requested = parameters['scripts'] or {row['id']: row['observation_id'] for row in added}
            result = recovery.inspect_scripts(value, home, requested, parameters.get('shell_script_policy'), paths)
        except (OSError, ValueError) as exc:
            reason = str(exc)
            raise CaptureError(reason if reason == 'script_path_unsupported' else 'capture_source_unavailable') from exc
        event('result', {'scripts': result, 'shell_script_policy': parameters.get('shell_script_policy'),
                         **({'shell_script_candidates': added} if paths else {})})
        event('completed')
        return 0
    target = destination(parameters['destination'], parameters.get('replacement_sha256')) if operation == 'capture_execute' else None
    published = False
    try:
        with PrivateTemporaryDirectory(prefix='macseed-capture-', dir='/private/tmp') as temporary:
            stage = Path(temporary)
            os.chmod(stage, 0o700)
            paths = operation_paths(parameters['_operation_id']) if parameters.get('external_identities') else []
            if operation == 'capture_identity_inspect':
                if len(paths) != 1:
                    raise CaptureError('external_identity_invalid_request')
                entry = external_inventory(root, stage, paths)[0]
                event('result', {'identity': {k: v for k, v in entry.items() if not k.startswith('_')}})
                event('completed')
                return 0
            rows, secure, environment = scan(root, stage, event)
            observed_functions = functions.Observation(root)
            shell_row = next(row for row in rows if row['domain'] == 'shell-zsh')
            if observed_functions.entries():
                shell_row['_legacy'] = dict(shell_row)
                legacy_ids = {row['item_id'] for row in shell_row['items']}
                shell_row.update(status='present', selection_mode='items', reason='source_partial',
                                 items=[*shell_row['items'], *(row for row in observed_functions.entries() if row['item_id'] not in legacy_ids)])
            event('capture_category', {key: shell_row[key] for key in ('domain', 'status', 'reason')})
            event('phase_completed', {'phase': 'discovery'})
            if paths:
                secure = add_external(secure, external_inventory(root, stage, paths))
            private = {}
            script_selection = parameters.get('shell_script_selection')
            script_policy = parameters.get('shell_script_policy')
            if parameters.get('shell_script_paths'):
                if operation == 'capture_execute' and set(parameters.get('shell_script_ids', [])) != set(script_selection or []):
                    raise CaptureError('invalid_script_consent')
                # The picker only supplies references. Existing recovery owns all
                # reads/validation and stages the negotiated payload before planning.
                # Unselected manual files never enter the staged snapshot.
                contract = bundle.shell_contract().recovery_contract()
                shell_path = stage / 'generated/shell/zshrc.snapshot'
                shell = bundle.shell_load(shell_path) if shell_path.exists() else contract.empty_capture()
                if shell is None and not (parameters['selection'] or {}).get('items', {}).get('shell-zsh') and 'shell-zsh' not in (parameters['selection'] or {}).get('categories', []):
                    shell = contract.empty_capture()
                typed_ids = typed_selection(parameters['selection'], rows)
                if shell is None and typed_ids and observed_functions.snapshot is not None:
                    # A qualified complex Function may exceed the legacy source
                    # observer. Reuse the same file-inspection context as the
                    # picker, then enforce actual typed alias/source exclusions.
                    shell = contract.capture(os.environ['HOME'], allow_empty=True)
                if shell is None or shell['version'] not in (3, 4, 5) or not script_selection or parameters['selection'] is None:
                    raise CaptureError('invalid_script_consent')
                try:
                    manual = contract.manual_paths(shell, os.environ['HOME'], parameters['shell_script_paths'])
                    if typed_ids and observed_functions.snapshot is not None:
                        observed_functions.validate_script_paths(typed_ids, manual)
                    if not {contract.script_id(path) for path in manual} <= set(script_selection):
                        raise CaptureError('invalid_script_consent')
                    shell = contract.authorize_capture(shell, os.environ['HOME'], script_selection,
                                                       policy=script_policy, script_paths=manual)
                except (OSError, ValueError) as exc:
                    raise CaptureError('script_transfer_unsupported') from exc
                contract.save(shell_path, shell)
                row = next(row for row in rows if row['domain'] == 'shell-zsh')
                row.update(status='present', selection_mode='items')
                if not shell['aliases']:
                    row['reason'] = None
            result, chosen, identities = prepared(stage, rows, secure, parameters['selection'], private, script_selection, script_policy,
                                                  observed_functions)
            typed = private.get('typed_shell')
            if identities and DESKTOP_BUNDLE in os.environ and not age_executable():
                raise CaptureError('age_unavailable')
            if operation == 'capture_prepare':
                if script_selection:
                    contract = bundle.shell_contract()
                    original = bundle.checked_file(stage / 'generated/shell/zshrc.snapshot')
                    shell = bundle.shell_load(stage / 'generated/shell/zshrc.snapshot') if script_policy in ('opaque-file-v4', 'opaque-file-v5') else contract.snapshot(contract.select_snapshot(original, chosen['shell-zsh']))
                    try:
                        contract.recovery_contract().authorize_capture(shell, os.environ['HOME'], script_selection, private.get('shell_dependencies'), script_policy)
                    except (OSError, ValueError) as exc:
                        raise CaptureError('script_transfer_unsupported') from exc
                event('result', result)
                event('completed')
                return 0
            event('phase_started', {'phase': 'validation'})
            if parameters['expected_prepared_capture_id'] != result['prepared_capture_id']:
                raise CaptureError('stale_prepared_capture')
            if identities and channel is None:
                raise CaptureError('secure_bridge_required')
            if identities and not age_executable():
                raise CaptureError('age_unavailable')
            blueprint(stage, chosen)
            if chosen.get('ssh-configuration'):
                bundle.select_ssh_profiles(stage, chosen['ssh-configuration'])
            if typed is not None:
                raw, payloads = typed
                previous_shell = bundle.shell_load(stage / functions.state.SNAPSHOT)
                previous_payloads = (bundle.shell_contract().recovery_contract().contents(previous_shell)
                                     if previous_shell is not None and previous_shell['version'] == 5 else {})
                for name in set(previous_payloads) - set(payloads):
                    (stage / name).unlink()
                typed_path = (stage / functions.state.SNAPSHOT).with_name('zshrc.typed')
                bundle.write_file(typed_path, raw)
                typed_path.replace(stage / functions.state.SNAPSHOT)
                for name, data in payloads.items():
                    temporary = (stage / name).with_suffix('.typed')
                    bundle.write_file(temporary, data)
                    temporary.replace(stage / name)
            elif chosen.get('shell-zsh') and not (script_policy in ('opaque-file-v4', 'opaque-file-v5') and parameters.get('shell_script_ids')):
                bundle.select_shell_aliases(stage, chosen['shell-zsh'])
            approvals = parameters.get('shell_script_ids', [])
            if script_selection is not None and set(approvals) != set(script_selection):
                raise CaptureError('invalid_script_consent')
            if approvals and typed is None:
                shell_path = stage / 'generated/shell/zshrc.snapshot'
                if 'shell-zsh' not in chosen:
                    raise CaptureError('invalid_script_consent')
                contract = bundle.shell_contract()
                shell = bundle.shell_load(shell_path)
                if shell['version'] not in (3, 4, 5):
                    raise CaptureError('invalid_script_consent')
                try:
                    shell = contract.recovery_contract().authorize_capture(shell, os.environ['HOME'], approvals, private.get('shell_dependencies'), script_policy)
                    if script_policy in ('opaque-file-v4', 'opaque-file-v5'):
                        shell = contract.recovery_contract().select(shell, {*chosen['shell-zsh'], *('shell-script:' + key for key in approvals)})
                except (OSError, ValueError) as exc:
                    raise CaptureError('script_transfer_unsupported') from exc
                contract.recovery_contract().save(shell_path, shell)
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
            for identity in identities:
                if identity.get('source') == 'manual' and external_pair(identity['_source_path'])[3] != identity['_stamp']:
                    raise CaptureError('stale_prepared_capture')
            event('phase_started', {'phase': 'bundle_creation'})
            if typed is not None and functions.Observation(root).binding != observed_functions.binding:
                raise CaptureError('stale_prepared_capture')
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
    except ExternalSourceError as exc:
        raise CaptureError(exc.code) from None
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


def ssh_row(destination_path, source, status, reason):
    entries = []
    if status != 'observation_error':
        try:
            contract = bundle.ssh_contract()
            _, coverage, _, profiles = contract.snapshot(contract.read_snapshot(source))
            if coverage in ('unsupported', 'external'):
                status, reason = 'unsupported', 'source_excluded'
            elif not profiles:
                status, reason = 'unavailable', 'no_supported_items'
            elif len(profiles) > MAX_ITEMS:
                raise ValueError('oversized SSH inventory')
            else:
                status, reason = 'present', 'source_partial' if coverage == 'partial' else None
                entries = [dict(item_id=item('ssh-configuration', host), label=host, _source=host)
                           for host in profiles]
        except (OSError, ValueError):
            status, reason = 'observation_error', 'inventory_invalid'
    value = dict(domain='ssh-configuration', status=status, reason=reason or None,
                 selection_mode='items', items=entries)
    with open(destination_path, 'a', encoding='utf-8') as output:
        os.chmod(destination_path, 0o600)
        output.write(json.dumps(value, sort_keys=True) + '\n')


def shell_row(destination_path, source, status, reason):
    entries, mode = [], 'category'
    if status != 'observation_error':
        try:
            raw = bundle.checked_file(Path(source), 66000)
            aliases = bundle.shell_aliases(raw)
            if aliases is not None:
                mode = 'items'
                status, reason = 'present', 'source_partial' if aliases['coverage'] == 'partial' else None
                entries = [dict(item_id=bundle.shell_contract().identity(row['name']), label=row['name'], _source=row['name'])
                           for row in aliases['aliases']]
            elif raw.startswith(b'MBT-ZSHRC-1\nstatus=eligible\n'):
                status, reason = 'present', None
            elif raw.startswith(b'MBT-ZSHRC-1\nstatus=absent\n'):
                status, reason = 'unavailable', 'source_absent'
            elif raw.startswith(b'MBT-ZSHRC-1\nstatus=excluded\n'):
                status, reason = 'unsupported', 'source_excluded'
            else:
                raise ValueError()
        except FileNotFoundError:
            status, reason = 'unavailable', 'source_absent'
        except (OSError, ValueError, bundle.Invalid):
            status, reason = 'observation_error', 'inventory_invalid'
    value = dict(domain='shell-zsh', status=status, reason=reason or None, selection_mode=mode, items=entries)
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
    if len(sys.argv) == 6 and sys.argv[1] == '--shell-row':
        shell_row(*sys.argv[2:])
    elif len(sys.argv) == 6 and sys.argv[1] == '--ssh-row':
        ssh_row(*sys.argv[2:])
    elif len(sys.argv) == 6 and sys.argv[1] == '--workspace-row':
        workspace_row(*sys.argv[2:])
    elif len(sys.argv) == 3 and sys.argv[1] == '--row':
        row(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == '--path':
        print((bundle.SELECTABLE_ITEMS | bundle.CATEGORIES)[sys.argv[2]])
    else:
        sys.exit(2)
