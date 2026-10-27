"""Topology domain consumer inside owned Bootstrap, using the Phase 3 inspector.

The private context binds the confirmed scope to source, staged and published
inputs. No entrypoint accepts a new plan or infers additional Git selection.
"""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'modules/bundle'))
sys.path.insert(0, str(ROOT / 'modules/core/application-interface'))
import bundle
import restore_selection
from observation import read
from reporting import project
from homebrew_stop import State, KEY, StopAccepted
from topology_preview import Inspector, inspect, contract, discovery
from clone_execution import CloneExecutor, pending

KEY_CONTEXT = 'MACSEED_WORKSPACE_CONTEXT'
KEY_DIGEST = 'MACSEED_WORKSPACE_CONTEXT_DIGEST'


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def create_context(source, stage, source_id, stage_id, plan):
    files = restore_selection.staged_files(stage)
    evidence = inspect(files, os.environ['HOME'], read)
    if digest(evidence['fingerprint']) != plan['plan_diagnostics']['workspace_observation']:
        raise ValueError('workspace observation changed')
    value = dict(contract=1, source=str(Path(source).absolute()), stage=str(stage),
                 source_id=source_id, stage_id=stage_id, prepared_plan_id=plan['prepared_plan_id'],
                 evidence=evidence)
    path = stage.parent / 'workspace-execution.json'
    data = json.dumps(value, sort_keys=True).encode()
    bundle.write_file(path, data)
    return {KEY_CONTEXT: str(path), KEY_DIGEST: hashlib.sha256(data).hexdigest()}


class Consumer:
    def __init__(self):
        self.cancelled = False
        self.executor = None
        path = Path(os.environ[KEY_CONTEXT])
        self.context_path = path
        data = bundle.checked_file(path)
        info = path.lstat()
        if (info.st_uid != os.getuid() or info.st_mode & 0o077 or
                hashlib.sha256(data).hexdigest() != os.environ[KEY_DIGEST] or
                os.environ.get('MACSEED_APPLICATION_EXECUTION') != 'true' or
                os.environ.get('BUNDLE_RESTORE_ACTIVE') != 'true'):
            raise ValueError('invalid execution context')
        self.context = json.loads(data)
        self.stage = Path(self.context['stage'])
        self.home = Path.home().resolve(strict=True)
        self.files = restore_selection.staged_files(self.stage)
        self.check_inputs()
        self.sections, _ = bundle.parse_blueprint(self.files['blueprint.conf'])
        self.records = contract.repository_records(self.files[contract.REPOSITORIES])
        self.members = {member['item_id']: (group, member)
                        for group in contract.objects(self.files[contract.TOPOLOGY])['groups']
                        for member in group['members']}
        self.paths = {item: contract.portable(row['path'], self.home) for item, row in self.records.items()}

    def check_inputs(self):
        value = self.context
        if (hashlib.sha256(bundle.checked_file(self.context_path)).hexdigest() != os.environ[KEY_DIGEST] or
                bundle.fingerprint(Path(value['source'])) != value['source_id'] or
                bundle.fingerprint(self.stage) != value['stage_id'] or
                bundle.fingerprint(self.stage / 'generated') != bundle.fingerprint(bundle.CONFIG / 'generated') or
                bundle.checked_file(self.stage / 'blueprint.conf') != bundle.checked_file(bundle.CONFIG / 'blueprint.conf')):
            raise ValueError('workspace inputs changed')
        bundle.validate_workspace(self.files, home=str(self.home))

    def checkpoint(self):
        if self.cancelled:
            raise InterruptedError()
        if os.environ.get(KEY):
            State(os.environ[KEY]).boundary('workspace')
        self.check_inputs()
        if pending():
            raise ValueError('Git lifecycle unresolved')

    def cancel(self, *_):
        self.cancelled = True
        if self.executor is not None:
            self.executor.cancel()

    def observer(self):
        observer = Inspector(self.home, read, time.monotonic() + 120)
        observer.git = contract.git_executable()
        return observer

    def event(self, row, state, reason=None):
        identity = row.get('checkout_id', row['item_id'])
        record = project(['item', row['domain'], identity, row['action'], state, reason or ''])
        os.write(int(os.environ['MACSEED_REPORT_FD']), (json.dumps(record) + '\n').encode())

    def outcome(self, row, outcome, reason=None, changed=False):
        identity = row.get('checkout_id', row['item_id'])
        # Private shell bridge; the existing collector owns record IDs/aggregation.
        print('\t'.join(('operation', row['domain'], identity, row['action'], outcome,
                         reason or 'none', 'true' if changed else 'false')), flush=True)
        self.event(row, {'success': 'changed', 'noop': 'already_satisfied', 'failure': 'failed',
                         'skipped': 'skipped', 'cancelled': 'cancelled'}[outcome], reason)

    def parents(self, relative):
        """Create only missing parents, without following any symlink component."""
        descriptor = os.open(self.home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            for part in contract.relative(relative).split('/'):
                self.checkpoint()
                try:
                    child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
                except FileNotFoundError:
                    os.mkdir(part, mode=0o755, dir_fd=descriptor)
                    print('changed', flush=True)
                    child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
                os.close(descriptor)
                descriptor = child
        finally:
            os.close(descriptor)

    def preservation(self, entries, exclude=None):
        """Content/HEAD evidence for other existing members, including unselected ones."""
        digests = []
        deadline = time.monotonic() + 120
        for entry in entries:
            observer = self.observer()
            observer.deadline = deadline
            path = Path(entry['path'])
            if path == exclude:
                continue
            discovery.inside(path, self.home)
            state = observer.checkout(path)
            # Registration legitimately grows; only this member's state is bound.
            # Use a separate digest for files and own HEAD, not worktree-list output.
            observer.evidence = hashlib.sha256()
            observer.remember([str(path), state['origin'], state['oid'], state['branch'], state['dirty']])
            gitdir = Path(observer.line(path, 'rev-parse', '--absolute-git-dir'))
            observer.files(gitdir, b'index\0HEAD\0')
            for arguments in (('ls-files', '-z'), ('ls-files', '--others', '--exclude-standard', '-z'),
                              ('ls-files', '--others', '--ignored', '--exclude-standard', '-z')):
                evidence = observer.evidence.copy()
                raw = observer.run(path, *arguments)
                # The new selected nested destination is an authorized addition.
                # Preserve every other file in its enclosing checkout.
                if exclude is not None and path in exclude.parents:
                    prefix = str(exclude.relative_to(path)).encode()
                    raw = b''.join(name + b'\0' for name in raw.split(b'\0') if name and
                                   name.rstrip(b'/') != prefix and not name.startswith(prefix + b'/'))
                # Enumeration output includes the intentional nested addition;
                # bind only the filtered, independently hashed content below.
                observer.evidence = hashlib.sha256()
                observer.files(path, raw)
                file_digest = observer.evidence.hexdigest()
                observer.evidence = evidence
                observer.remember(file_digest)
            digests.append(observer.evidence.hexdigest())
        return digest(digests)

    def local_command(self, item, action):
        group, member = self.members[item]
        row = self.records[item]
        observer = self.observer()
        path = self.home / self.paths[item]
        base = self.home / self.paths[group['base_item_id']]
        target = row['branch'] if member['head_kind'] == 'branch' else member['head_oid']
        # Explicit local branch/commit, disabled guessing, no hooks, filters or lazy fetch.
        args = [observer.git, '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false',
                '-c', 'gc.auto=0', '-c', 'maintenance.auto=false', '-c', 'submodule.recurse=false',
                '-c', 'checkout.guess=false', '-c', 'worktree.guessRemote=false',
                '-c', 'worktree.useRelativePaths=false', '-c', 'protocol.allow=never', '-C']
        if action == 'add_worktree':
            # Worktree's explicit-name DWIM can create a tracking branch even
            # with --no-guess-remote. Add by exact OID, then attach an existing
            # local branch with checkout --no-guess under fresh inspection.
            if member['head_kind'] == 'branch':
                target = observer.line(base, 'rev-parse', '--verify', 'refs/heads/' + target + '^{commit}')
            args += [str(base), 'worktree', 'add', '--no-guess-remote', '--detach']
            args += ['--', str(path), target]
        else:
            args += [str(path), 'checkout', '--no-guess', '--no-overwrite-ignore', '--no-recurse-submodules']
            if member['head_kind'] == 'detached':
                args += ['--detach']
            args += [target, '--']
        return args, observer.environment

    def protected(self, path, names=None):
        observer = self.observer()
        if names is None:
            names = observer.run(path, 'ls-files', '--others', '--exclude-standard', '-z')
            names += observer.run(path, 'ls-files', '--others', '--ignored', '--exclude-standard', '-z')
        observer.evidence = hashlib.sha256()
        observer.files(path, names)
        return names, observer.evidence.hexdigest()

    def current_row(self, rows, row):
        return next(value for value in rows if (value['domain'], value['item_id']) == (row['domain'], row['item_id']))

    def execute(self):
        self.checkpoint()
        previous = inspect(self.files, self.home, read)
        if previous != self.context['evidence']:
            raise ValueError('stale workspace plan')
        failed = set()
        status = 0
        for authorized in self.context['evidence']['plan']:
            self.checkpoint()
            row = self.current_row(previous['plan'], authorized)
            item = row.get('checkout_id')
            if any(parent in failed for parent in row.get('dependency_ids', [])):
                row = dict(row, disposition='blocked', reason='workspace_dependency_pending')
            if row['disposition'] == 'satisfied':
                self.outcome(row, 'noop')
                continue
            if authorized['disposition'] != 'planned' or row['disposition'] != 'planned':
                self.outcome(row, 'skipped', row['reason'] or 'workspace_not_authorized')
                failed.add(item)
                status = 1
                continue
            if row['action'] != authorized['action'] or row['action'] == 'none':
                # A shared folder is completed only by its selected checkout.
                self.outcome(row, 'skipped', 'workspace_dependency_pending')
                failed.add(item)
                status = 1
                continue
            relative = self.paths[item] if item else row['item_id']
            path = self.home / relative
            if item and pending(path):
                self.outcome(row, 'skipped', 'workspace_partial_checkout')
                failed.add(item)
                status = 1
                continue
            if inspect(self.files, self.home, read) != previous:
                raise ValueError('workspace changed between actions')
            self.event(row, 'applying')
            verified_evidence = None
            if row['action'] == 'create_directory':
                self.parents(relative)
                good = self.observer().destination(relative) is not None
                self.outcome(row, 'success' if good else 'failure', changed=good)
                if not good:
                    return 2
            else:
                if '/' in relative:
                    self.parents(relative.rsplit('/', 1)[0])
                # Parent creation changes only directory evidence. Requalify the
                # entire selected scope immediately before native Git launch.
                now = inspect(self.files, self.home, read)
                current = self.current_row(now['plan'], row)
                if current['action'] != row['action'] or current['disposition'] != 'planned':
                    self.outcome(row, 'failure', 'workspace_observation_changed')
                    return 2
                group, member = self.members[item]
                base = self.home / self.paths[group['base_item_id']]
                entries = [] if row['action'] == 'clone' else self.observer().checkout(base)['entries']
                for parent in row.get('dependency_ids', []):
                    parent_path = self.home / self.paths[parent]
                    if parent_path != base or row['action'] == 'clone':
                        entries += self.observer().checkout(parent_path)['entries']
                entries = list({entry['path']: entry for entry in entries}.values())
                preserve = self.preservation(entries, exclude=path)
                protected = self.protected(path) if row['action'] == 'switch_branch' else None
                expected_oid = member['head_oid'] if member['head_kind'] == 'detached' else None
                if expected_oid is None and row['action'] != 'clone':
                    expected_oid = self.observer().line(base, 'rev-parse', '--verify',
                                                        'refs/heads/' + self.records[item]['branch'] + '^{commit}')
                head_step = ((row['action'] == 'clone' and member['head_kind'] == 'detached') or
                             (row['action'] == 'add_worktree' and member['head_kind'] == 'branch'))
                def verify():
                    nonlocal verified_evidence
                    self.check_inputs()
                    if self.preservation(entries, exclude=path) != preserve:
                        raise ValueError('other checkout changed')
                    if protected is not None and self.protected(path, protected[0]) != protected:
                        raise ValueError('protected files changed')
                    observed = inspect(self.files, self.home, read)
                    verified_evidence = observed
                    target = self.current_row(observed['plan'], row)
                    if expected_oid is not None and (target['disposition'] == 'satisfied' or
                            (head_step and row['action'] == 'add_worktree' and target['action'] == 'switch_branch')):
                        if self.observer().line(path, 'rev-parse', '--verify', 'HEAD^{commit}') != expected_oid:
                            raise ValueError('HEAD changed outside the qualified action')
                    # An initial detached worktree / default clone needs the
                    # confirmed final HEAD step; this is never final success.
                    return target['disposition'] == 'satisfied' or (
                        head_step and
                        target['action'] == 'switch_branch' and target['disposition'] == 'planned')
                self.checkpoint()
                if inspect(self.files, self.home, read) != now:
                    self.outcome(row, 'failure', 'workspace_observation_changed')
                    return 2
                self.executor = CloneExecutor(deadline=7200 if row['action'] == 'clone' else 120)
                if row['action'] == 'clone':
                    code, reason, safe = self.executor.run(self.records[item]['remote'], str(path),
                        self.records[item]['branch'], empty_destination=path.exists(), verify=verify)
                else:
                    args, env = self.local_command(item, row['action'])
                    def unchanged():
                        self.check_inputs()
                        return inspect(self.files, self.home, read) == now
                    code, reason, safe = self.executor.run_local(str(path), args, env, verify=verify, unchanged=unchanged,
                                                               require_unchanged=row['action'] == 'switch_branch')
                made_change = code == 0
                if code == 0 and head_step:
                    try:
                        self.checkpoint()
                    except StopAccepted:
                        self.outcome(row, 'cancelled', 'cancelled', changed=True)
                        raise
                    step_evidence = inspect(self.files, self.home, read)
                    current = self.current_row(step_evidence['plan'], row)
                    if step_evidence != verified_evidence:
                        self.outcome(row, 'failure', 'workspace_observation_changed', changed=True)
                        return 2
                    if current['disposition'] != 'satisfied' and not (
                            current['disposition'] == 'planned' and current['action'] == 'switch_branch'):
                        self.outcome(row, 'failure', 'workspace_observation_changed')
                        return 2
                    head_step = False
                    if current['disposition'] == 'satisfied':
                        if not verify():
                            self.outcome(row, 'failure', 'workspace_verification_failed', changed=True)
                            return 2
                    else:
                        protected = self.protected(path)
                        self.checkpoint()
                        if inspect(self.files, self.home, read) != step_evidence:
                            self.outcome(row, 'failure', 'workspace_observation_changed', changed=True)
                            return 2
                        args, env = self.local_command(item, 'switch_branch')
                        code, reason, safe = self.executor.run_local(str(path), args, env, verify=verify)
                self.outcome(row, 'success' if code == 0 else 'cancelled' if code == 130 else 'failure',
                             None if code == 0 else reason, changed=made_change)
                if code:
                    # Retain partials. No independent continuation after a native
                    # failure until unchanged state/isolation is proven.
                    return 130 if code == 130 and safe else 2
            previous = verified_evidence or inspect(self.files, self.home, read)
        return status

    def verification(self):
        self.check_inputs()
        rows = inspect(self.files, self.home, read)['plan']
        uncertain = pending()
        satisfied = {row['checkout_id'] for row in rows if row.get('checkout_id') and row['disposition'] == 'satisfied'}
        for row in rows:
            item = row.get('checkout_id', row['item_id'])
            result = 0 if row['disposition'] == 'satisfied' else 1 if row['disposition'] in ('planned', 'conflict') else 2
            if row.get('checkout_id') and (uncertain or pending(self.home / self.paths[item])):
                result = 2
            dependencies = row.get('dependency_ids', [])
            if row['domain'] == 'workspace-folders':
                # An existing shared folder satisfies structure independently
                # of a Git conflict at that same destination. Enclosing parent
                # checkouts still retain their dependency requirement.
                dependencies = [parent for parent in dependencies if self.paths[parent] != row['item_id']]
            if any(parent not in satisfied for parent in dependencies):
                result = 2
            predicate = 'topology' if row['domain'] == 'git-repositories' else 'directory'
            print('\t'.join((row['domain'], item, predicate, str(result))), flush=True)


def main():
    try:
        consumer = Consumer()
        if sys.argv[1:] == ['--validate']:
            return 0
        if sys.argv[1:] == ['--verify']:
            consumer.verification()
            return 0
        if sys.argv[1:] != ['--execute']:
            return 2
        os.environ['MACSEED_GIT_CLONE_RESTORE'] = 'true'
        signal.signal(signal.SIGTERM, consumer.cancel)
        signal.signal(signal.SIGINT, consumer.cancel)
        return consumer.execute()
    except StopAccepted:
        return 132
    except InterruptedError:
        return 130
    except (OSError, ValueError, KeyError, RuntimeError, TypeError, subprocess.SubprocessError):
        # The shell owns the fixed failure record; never expose private exceptions.
        return 2


if __name__ == '__main__':
    sys.exit(main())
