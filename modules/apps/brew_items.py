"""Homebrew domain dependency gating over the shared owned-item watchdog."""
import json
import os
from pathlib import Path
import re
import signal
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'core/application-interface'))
from item_execution import ItemExecutor, STALLED, BLOCKED, UNOBSERVABLE, OBSERVATION_FAILED, CANCELLED


def valid_name(name):
    if not isinstance(name, str) or name.lower().endswith('.rb'):
        return False
    parts = name.split('/')
    return len(parts) in (1, 3) and all(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9+_.@-]*', part) for part in parts)


class BrewItemExecutor(ItemExecutor):
    def info(self, kind, name):
        status, raw = self.run(['brew', 'info', '--json=v2', '--' + kind, name], capture=True)
        if status:
            raise RuntimeError('dependency_observation_failed')
        data = json.loads(raw)
        row = data['formulae' if kind == 'formula' else 'casks'][0]
        canonical = row['full_name' if kind == 'formula' else 'token']
        if not valid_name(canonical):
            raise ValueError('invalid formula identity')
        if kind == 'formula':
            dependencies = row.get('dependencies', []) + row.get('build_dependencies', []) + row.get('recommended_dependencies', [])
            pairs = [('formula', name) for name in dependencies]
        else:
            dependency = row.get('depends_on') or {}
            pairs = []
            for category, dependency_kind in [('formula', 'formula'), ('cask', 'cask')]:
                values = dependency.get(category, [])
                if isinstance(values, str):
                    values = [values]
                pairs += [(dependency_kind, name) for name in values]
        if any(not valid_name(name) for _, name in pairs):
            raise ValueError('invalid dependency identity')
        return kind + ':' + canonical, pairs

    def execute(self, kind, name, command, directory):
        ledger = directory / 'failed-items.json'
        failed = set(json.loads(ledger.read_text())) if ledger.exists() else set()
        skipped = directory / 'skipped-casks.json'
        if skipped.exists():
            # Seed all accepted skips before evaluating dependencies, regardless
            # of execution order. Current safe casks have no formula/cask deps.
            failed.update('cask:' + token for token in json.loads(skipped.read_text()))
        canonical = 'unresolved:' + kind + ':' + name
        try:
            canonical, dependencies = self.info(kind, name)
            if dependencies and any(value.startswith('unresolved:') for value in failed):
                raise RuntimeError('dependency_observation_failed')
            pending = list(dependencies) if failed else []
            visited = {canonical}
            while pending:
                dependency_kind, dependency_name = pending.pop()
                identity, children = self.info(dependency_kind, dependency_name)
                if identity in failed:
                    self.reason = 'dependency_failed'
                    status = BLOCKED
                    break
                if identity not in visited:
                    visited.add(identity); pending.extend(children)
            else:
                status, _ = self.run(command)
                if status and self.reason is None:
                    self.reason = 'item_install_failed'
        except (KeyError, IndexError, TypeError, ValueError, OSError, RuntimeError):
            status = CANCELLED if self.cancelled else STALLED if self.reason == 'item_stalled_timeout' else OBSERVATION_FAILED if self.reason == 'progress_observation_failed' else UNOBSERVABLE
            self.reason = self.reason or 'dependency_observation_failed'
        if status != CANCELLED:
            # Not ready until the authoritative Bash consumer verifies installation.
            identities = directory / 'item-identities.json'
            mapping = json.loads(identities.read_text()) if identities.exists() else {}
            mapping[kind + ':' + name] = canonical
            identity_temp = identities.with_suffix('.tmp')
            identity_temp.write_text(json.dumps(mapping)); identity_temp.chmod(0o600)
            identity_temp.replace(identities)
            failed.add(canonical)
            temporary = ledger.with_suffix('.tmp')
            temporary.write_text(json.dumps(sorted(failed)))
            temporary.chmod(0o600); temporary.replace(ledger)
        return status


def main():
    arguments = sys.argv[1:]
    verified = arguments[0:1] == ['--verified']
    skip_reason = arguments[0:1] == ['--skip-reason']
    if verified or skip_reason:
        arguments = arguments[1:]
    domain, name, *command = arguments
    if domain not in ('homebrew-packages', 'homebrew-casks') or (not command and not verified and not skip_reason) or os.environ.get('MACSEED_APPLICATION_EXECUTION') != 'true':
        return 2
    directory = Path(os.environ['MACSEED_ITEM_STATE_DIR'])
    kind = 'formula' if domain == 'homebrew-packages' else 'cask'
    if skip_reason:
        try:
            skipped = directory / 'skipped-casks.json'
            if domain == 'homebrew-casks' and skipped.exists() and name in json.loads(skipped.read_text()):
                print('cask_execution_requirements_unsupported')
            return 0
        except (OSError, ValueError, TypeError):
            return 2
    if verified:
        try:
            identities = json.loads((directory / 'item-identities.json').read_text())
            canonical = identities[kind + ':' + name]
            ledger = directory / 'failed-items.json'
            failed = set(json.loads(ledger.read_text())); failed.discard(canonical)
            temporary = ledger.with_suffix('.tmp')
            temporary.write_text(json.dumps(sorted(failed))); temporary.chmod(0o600)
            temporary.replace(ledger)
            return 0
        except (OSError, ValueError, KeyError):
            return 2
    executor = BrewItemExecutor()
    signal.signal(signal.SIGTERM, executor.cancel)
    signal.signal(signal.SIGINT, executor.cancel)
    return executor.execute(kind, name, command, directory)


if __name__ == '__main__':
    sys.exit(main())
