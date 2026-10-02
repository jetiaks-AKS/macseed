"""Privacy projection of production records, never a state observer."""
import hashlib
import json
import os
import re
import sys

sys.dont_write_bytecode = True
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
        action, outcome, reason = values
        result.update(action=token(action), outcome=token(outcome), reason=token(reason) if reason else None)
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
