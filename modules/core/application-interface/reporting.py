"""Privacy projection of production records, never a state observer."""
import sys
sys.dont_write_bytecode = True

import hashlib
import json
import os
import re
import stat
import tempfile
from contextlib import contextmanager

OBSERVATION_REPORT = 'MACSEED_OBSERVATION_REPORT'
OBSERVATION_REASONS = frozenset({'external_observation_process', 'external_observation_launch',
    'external_observation_failed', 'external_observation_deadline', 'external_observation_limit',
    'external_observation_worker', 'external_observation_unquiescent', 'external_observation_native'})


@contextmanager
def observation_reporting():
    """Private operation scratch feeding the existing Protocol/Operation Log."""
    # Never accept a caller-supplied report destination.
    os.environ.pop(OBSERVATION_REPORT, None)
    with tempfile.TemporaryDirectory(prefix='macseed-observation-', dir='/private/tmp') as directory:
        path = os.path.join(directory, 'failures.jsonl')
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(descriptor)
        os.environ[OBSERVATION_REPORT] = path
        try:
            yield
        finally:
            os.environ.pop(OBSERVATION_REPORT, None)


def observation_failure(command, reason, elapsed, native_status, quiescent):
    """No argv, paths, output, environment or exception text cross this boundary."""
    path = os.environ.get(OBSERVATION_REPORT)
    if not path or reason not in OBSERVATION_REASONS:
        return
    tool = 'homebrew' if os.path.basename(command[0]) == 'brew' else 'other'
    probe = {'--version': 'version', '--prefix': 'prefix', 'list': 'inventory',
             'info': 'metadata', 'help': 'capability'}.get(command[1] if len(command) > 1 else '', 'read') if tool == 'homebrew' else 'read'
    value = dict(tool=tool, probe=probe, reason=reason, phase='observation',
                 duration_ms=min(1_000_000_000, max(0, int(elapsed * 1000))), quiescent=quiescent)
    if native_status is not None:
        value['native_exit_code' if native_status >= 0 else 'native_signal'] = abs(native_status)
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            info = os.fstat(descriptor)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_mode & 0o077 or info.st_nlink != 1 or info.st_size >= 32768):
                return
            os.write(descriptor, (json.dumps(value, separators=(',', ':')) + '\n').encode())
        finally:
            os.close(descriptor)
    except OSError:
        pass  # Diagnostic availability cannot change the observation outcome.


def observation_failures():
    path = os.environ.get(OBSERVATION_REPORT)
    if not path:
        return []
    try:
        with open(path, 'rb') as stream:
            data = stream.read(32768)
        values = []
        for line in data.split(b'\n')[:-1][:64]:
            value = json.loads(line)
            if (set(value) <= {'tool', 'probe', 'reason', 'phase', 'duration_ms', 'quiescent', 'native_exit_code', 'native_signal'}
                    and value.get('tool') in {'homebrew', 'other'}
                    and value.get('probe') in {'version', 'prefix', 'inventory', 'metadata', 'capability', 'read'}
                    and value.get('reason') in OBSERVATION_REASONS and value.get('phase') == 'observation'
                    and type(value.get('quiescent')) is bool
                    and type(value.get('duration_ms')) is int and 0 <= value['duration_ms'] <= 1_000_000_000
                    and all(type(value[k]) is int and 0 <= value[k] <= 255 for k in ('native_exit_code', 'native_signal') if k in value)):
                values.append(value)
        return values
    except (OSError, ValueError, TypeError):
        return []

MAX_RECORDS = 8192
MAX_LINE = 4096
MODULES = {
    'bootstrap_workspace': 'workspace', 'bundle_restore_prerequisites': 'ssh-prerequisites',
    'configure_bs_launcher': 'launcher', 'configure_git': 'git-configuration',
    'install_brew_packages': 'homebrew-packages', 'install_brew_casks': 'homebrew-casks',
    'install_appstore_apps': 'app-store', 'install_vscode_extensions': 'vscode-extensions',
    'apply_vscode_settings': 'vscode-settings', 'bootstrap_zsh': 'shell-zsh',
    'bootstrap_ssh_configuration': 'ssh-configuration',
    'verification_run': 'verification', 'check_finder': 'macos-finder', 'check_dock': 'macos-dock', 'check_windows': 'macos-windows',
    'check_keyboard': 'macos-keyboard', 'check_trackpad': 'macos-trackpad', 'check_screenshots': 'macos-screenshots',
}
PUBLIC_ITEMS = {'homebrew-packages', 'homebrew-casks', 'app-store', 'vscode-extensions',
                'git-configuration', 'macos-finder', 'macos-dock', 'macos-windows',
                'macos-keyboard', 'macos-trackpad', 'macos-screenshots'}


def opaque(subject):
    return 'opaque:' + hashlib.sha256(subject.encode()).hexdigest()


def item(domain, subject):
    if domain == 'vscode-workspaces' and re.fullmatch(r'workspace-[0-9a-f]{64}', subject):
        return subject
    if subject in {'scope', 'secure-selection', 'settings.json', 'config', 'zshrc', 'execute', 'bootstrap'}:
        return subject
    if domain in PUBLIC_ITEMS and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.+@/ -]{0,255}', subject):
        return subject
    if domain == 'workspace-folders' and not subject.startswith('/') and not re.search(r'[\x00-\x1f\x7f:@]', subject):
        return subject
    return opaque(subject)


def project(fields):
    kind, *values = fields
    def token(value):
        return value if re.fullmatch(r'[a-z][a-z0-9_-]{0,63}', value) else 'redacted'
    if kind == 'comparison_summary':
        status, verdict, incomplete, *counts = values
        verdicts = {'Comparison incomplete': 'incomplete', 'Differences detected': 'differences_detected',
                    'No differences detected': 'no_differences_detected', 'No comparable requirements': 'no_comparable_requirements'}
        return {'kind': kind, 'status': status, 'verdict': verdicts[verdict],
                'also_incomplete': incomplete == 'true',
                'counts': dict(zip(('matching', 'missing', 'differing', 'unverified', 'unsupported',
                                    'unresolved', 'extra', 'unknown_difference'), map(int, counts)))}
    if kind == 'extra_status':
        domain, state, count, reason = values
        return {'kind': kind, 'domain': token(domain), 'status': token(state),
                'count': int(count) if count else None, 'reason': token(reason) if reason else None}
    if kind == 'extra':
        domain, subject = values
        return {'kind': kind, 'domain': token(domain), 'item_id': item(domain, subject)}
    if kind == 'comparison':
        reference, domain, subject, category, reason, phase, support = values
        return {'kind': kind, 'record_id': reference, 'domain': token(domain), 'item_id': item(domain, subject),
                'comparison_kind': token(category), 'reason': token(reason) if reason else None,
                'phase': token(phase) if phase else None, 'support': token(support)}
    if kind == 'item':
        domain, subject, action, state, reason = values
        return {'kind': 'lifecycle', 'domain': token(domain), 'item_id': item(domain, subject),
                'action': token(action), 'state': token(state), 'reason': token(reason) if reason else None}
    if kind == 'module':
        function, phase, result, changed = values
        domain = MODULES.get(function)
        if domain is None:
            return None
        state = phase if phase != 'finished' else (
            'failed' if result not in ('0', '1') else 'warning' if result == '1' else
            'changed' if changed == 'true' else 'already_satisfied')
        return {'kind': 'lifecycle', 'domain': domain, 'item_id': 'scope',
                'action': 'verify' if domain == 'verification' else 'restore', 'state': state,
                'changed': changed == 'true',
                'reason': 'module_failed' if state == 'failed' else 'module_warning' if state == 'warning' else None}
    if kind == 'reporting_failed':
        return {'kind': 'reporting_failed'}
    if kind == 'truncated':
        return {'kind': 'truncated'}
    if kind == 'complete':
        return {'kind': 'details_complete'}
    if kind == 'diagnostic':
        owner, code, severity, phase = values
        return {'kind': kind, 'record_id': owner, 'code': token(code), 'severity': token(severity), 'phase': token(phase)}
    reference, domain, subject, *values = values
    result = {'kind': kind, 'record_id': reference, 'domain': domain, 'item_id': item(domain, subject)}
    if kind == 'verification':
        predicate, conformity, support, observed = values
        result.update(predicate=token(predicate), conformity=token(conformity), support=token(support), observed_at=observed or None)
    elif kind == 'coverage':
        disposition, source_status = values
        if disposition == 'excluded' and os.environ.get('MACSEED_APPLICATION_COMPARE') != 'true':
            return None
        result.update(disposition=disposition, source_status=source_status)
    elif kind == 'operation':
        action, outcome, reason, *native = values
        result.update(action=token(action), outcome=token(outcome), reason=token(reason) if reason else None)
        if len(native) > 1:
            raise ValueError('invalid native exit')
        if native and native[0]:
            if not native[0].isascii() or not native[0].isdigit() or not 0 <= int(native[0]) <= 255:
                raise ValueError('invalid native exit')
            result['native_exit_code'] = int(native[0])
    else:
        raise ValueError('unknown record')
    return result


if __name__ == '__main__':
    fields = sys.stdin.buffer.read(16384).decode().split('\0')
    if fields[-1] != '':
        sys.exit(2)
    record = project(fields[:-1])
    if record is not None:
        raw = json.dumps(record, ensure_ascii=True, separators=(',', ':'))
        if len(raw) + 1 > MAX_LINE:
            sys.exit(2)
        print(raw, flush=True)
