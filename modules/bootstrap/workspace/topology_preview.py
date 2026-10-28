"""Read-only target evidence for Core Prepare; no publication or Apply entrypoint.

Reuse the topology contract and Discovery's qualified Git readers. The caller
owns Bundle/Selection validation and the existing Protocol V1 plan identity.
"""
import hashlib
from contextlib import ExitStack, contextmanager
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
import unicodedata

import bundle

sys.path.insert(0, str(Path(__file__).resolve().parent))

_spec = importlib.util.spec_from_file_location('workspace_observation',
    Path(__file__).resolve().parents[2] / 'discovery/workspace/topology.py')
discovery = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(discovery)
contract = discovery.contract

# Exceptions from the shared readers are internal, not public diagnostics.
# Only these fixed reasons may cross Protocol V1 / Desktop privacy boundaries.
UNSUPPORTED_REASONS = {code: code for code in (
    'workspace_git_unsupported', 'workspace_file_count_limit', 'workspace_file_bytes_limit',
    'workspace_symlink_unsupported', 'workspace_file_unsupported', 'workspace_configuration_unsupported',
    'workspace_index_unsupported', 'workspace_hooks_unsupported', 'workspace_tree_unsupported',
    'workspace_submodule_unsupported', 'workspace_path_unsupported', 'workspace_git_metadata_unsupported')}
UNSUPPORTED_REASONS.update({
    'git_external_configuration': 'workspace_configuration_unsupported',
    'git_metadata_symlink': 'workspace_git_metadata_unsupported',
    'gitfile_unsupported': 'workspace_git_metadata_unsupported',
    'external_workspace_path': 'workspace_path_unsupported',
    'checkout_root_mismatch': 'workspace_worktree_unsupported',
    **{code: 'workspace_worktree_unsupported' for code in (
        'worktree_format_unsupported', 'worktree_path_ambiguous', 'worktree_branch_unsupported',
        'worktree_inventory_oversized')},
})


class Conflict(ValueError):
    pass


@contextmanager
def directory_fd(home, relative=''):
    """Anchor all components to HOME; never open through a symlink."""
    descriptor = os.open(home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in contract.relative(relative).split('/') if relative else ():
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        yield descriptor
    finally:
        os.close(descriptor)


def workspace_folders(workspace, paths):
    result = []
    for folder in workspace['folders']:
        parent = paths[folder['item_id']] if folder['domain'] == 'git-repositories' else folder['item_id']
        target = parent + ('/' + folder['subpath'] if folder['subpath'] else '')
        result.append(dict(path=target, **({'name': folder['name']} if 'name' in folder else {})))
    return result


def dependency_id(domain, item):
    # Keep folder dependencies opaque and distinct from checkout identities.
    return 'folder-' + hashlib.sha256(item.encode()).hexdigest() if domain == 'workspace-folders' else item


def related(left, right):
    left, right = (unicodedata.normalize('NFC', value).casefold().rstrip('/') for value in (left, right))
    return left == right or left.startswith(right + '/') or right.startswith(left + '/')


class Inspector(discovery.Observer):
    def __init__(self, home, reader, deadline):
        super().__init__(home, [])
        self.source_home = str(home)
        self.environment['GIT_NO_REPLACE_OBJECTS'] = '1'
        self.reader = reader
        self.deadline = deadline
        self.evidence = hashlib.sha256()
        self.identities = {}
        self.bytes_read = 0

    def remember(self, value):
        self.evidence.update(json.dumps(value, sort_keys=True, separators=(',', ':')).encode() + b'\0')

    def run(self, path, *args, absent=False, hook_config=False):
        # The application reader bounds output, lifetime and owned descendants.
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise discovery.ObservationError('workspace_observation_failed')
        environment = self.environment
        if hook_config:
            # Read hook routing from native local/global/system configuration,
            # without following includes or changing other Git observations.
            assert args[0] == 'config' and '--no-includes' in args
            environment = {key: value for key, value in environment.items() if key not in (
                'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM', 'GIT_CONFIG_NOSYSTEM')}
        result = self.reader([self.git, '-c', 'core.fsmonitor=false', '-c', 'core.untrackedCache=false',
                              '-c', 'submodule.recurse=false', '--no-optional-locks',
                              '-C', str(path), *args], min(15, remaining), env=environment)
        self.remember([str(path), args, result.returncode, hashlib.sha256(result.stdout).hexdigest()])
        if absent and result.returncode == 1 and not result.stdout:
            return b''
        if result.returncode or len(result.stdout) > contract.MAX_BYTES:
            raise discovery.ObservationError('workspace_observation_failed')
        return result.stdout

    def destination(self, relative):
        path = self.home
        for part in contract.relative(relative).split('/'):
            path /= part
            try:
                info = path.lstat()
            except FileNotFoundError:
                self.remember([str(path), 'absent'])
                return None
            self.remember([str(path), info.st_dev, info.st_ino, info.st_mode])
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
                raise Conflict('workspace_destination_conflict')
            if not os.access(path, os.R_OK | os.X_OK):
                raise PermissionError()
        key = (info.st_dev, info.st_ino)
        if key in self.identities and self.identities[key] != relative:
            raise Conflict('workspace_destination_conflict')
        self.identities[key] = relative
        return path

    def workspace(self, workspace, expected):
        def identity(info):
            return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)

        if time.monotonic() >= self.deadline:
            raise ValueError('descriptor observation deadline')
        relative = contract.portable(workspace['path'])
        parent, _, name = relative.rpartition('/')
        if parent and self.destination(parent) is None:
            return False, False
        with directory_fd(self.home, parent) as directory:
            try:
                before = os.stat(name, dir_fd=directory, follow_symlinks=False)
            except FileNotFoundError:
                self.remember([relative, 'absent'])
                return False, False
            if not stat.S_ISREG(before.st_mode):
                raise Conflict('workspace_descriptor_conflict')
            if before.st_size > contract.MAX_BYTES:
                raise ValueError('descriptor observation limit')
            descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
            try:
                opened = os.fstat(descriptor)
                if not stat.S_ISREG(opened.st_mode) or identity(opened) != identity(before):
                    raise ValueError('descriptor changed')
                data = b''
                while len(data) <= contract.MAX_BYTES:
                    chunk = os.read(descriptor, min(65536, contract.MAX_BYTES + 1 - len(data)))
                    if not chunk:
                        break
                    data += chunk
                if (len(data) != before.st_size or identity(os.fstat(descriptor)) != identity(opened) or
                        identity(os.stat(name, dir_fd=directory, follow_symlinks=False)) != identity(before)):
                    raise ValueError('descriptor changed')
            finally:
                os.close(descriptor)
        self.remember([relative, before.st_dev, before.st_ino, before.st_mode, before.st_size,
                       before.st_mtime_ns, before.st_ctime_ns, hashlib.sha256(data).hexdigest()])
        value = discovery.jsonc(data)
        if not isinstance(value, dict) or not isinstance(value.get('folders'), list):
            return True, False
        if len(value['folders']) > contract.MAX_ITEMS:
            raise ValueError('descriptor folder limit')
        actual = []
        for folder in value['folders']:
            if time.monotonic() >= self.deadline:
                raise ValueError('descriptor observation deadline')
            if not isinstance(folder, dict) or set(folder) - {'path', 'name'} or 'path' not in folder:
                return True, False
            raw = contract.text(folder['path'])
            # Relative ../ links are needed for siblings. Qualify every prefix
            # before normalization so a symlink/../ cannot hide a traversal.
            current = self.home if raw.startswith('/') else self.home / parent
            parts = Path(raw).relative_to(self.home).parts if raw.startswith('/') else raw.split('/')
            for part in parts:
                if part in ('', '.'):
                    continue
                current = current.parent if part == '..' else current / part
                if current != self.home:
                    target = str(current.relative_to(self.home))
                    contract.relative(target)
                    self.destination(target)
            target = str(current.relative_to(self.home))
            contract.relative(target)
            actual.append(dict(path=target, **({'name': folder['name']} if 'name' in folder else {})))
        return True, actual == expected

    def workspaces(self, files, paths, result):
        sections, _ = bundle.parse_blueprint(files['blueprint.conf'])
        selected = sections.get('vscode-workspaces', [])
        if not selected:
            return
        items = {row['item_id']: row for row in contract.objects(files[contract.VSCODE])['items']}
        completed = {dependency_id(row['domain'], row.get('checkout_id', row['item_id'])): row for row in result}
        for item in selected:
            workspace = items[item]
            relative = contract.portable(workspace['path'])
            expected = workspace_folders(workspace, paths)
            dependencies = {dependency_id(folder['domain'], folder['item_id']) for folder in workspace['folders']}
            dependencies.update(key for key, path in paths.items()
                                if key in sections['git-repositories'] and contract.within(relative, path))
            # Include base/parent dependencies already qualified by the Git plan.
            for key in list(dependencies):
                dependencies.update(completed[key].get('dependency_ids', []))
            try:
                exists, matches = self.workspace(workspace, expected)
                targets_exist = all([self.destination(folder['path']) is not None for folder in expected])
                pending = any(completed[key]['disposition'] != 'satisfied' for key in dependencies)
                blocked = any(completed[key]['disposition'] not in ('planned', 'satisfied') for key in dependencies)
                if exists and not matches:
                    action, disposition, reason = 'inspect', 'conflict', 'workspace_descriptor_conflict'
                elif blocked:
                    action, disposition, reason = 'inspect', 'blocked', 'workspace_dependency_pending'
                elif not targets_exist and not pending:
                    action, disposition, reason = 'inspect', 'blocked', 'workspace_relationship_missing'
                elif exists and not pending and targets_exist:
                    action, disposition, reason = 'none', 'satisfied', None
                else:
                    action, disposition, reason = ('none' if exists else 'create_workspace'), 'planned', (
                        'workspace_dependency_pending' if pending else None)
            except Conflict as exc:
                action, disposition, reason = 'inspect', 'conflict', str(exc)
            except (OSError, ValueError, TypeError, RecursionError):
                action, disposition, reason = 'inspect', 'unknown', 'workspace_observation_failed'
            result.append(dict(domain='vscode-workspaces', item_id=item, action=action,
                               disposition=disposition, reason=reason,
                               display_name=contract.workspace_label(workspace['path']),
                               dependency_ids=sorted(dependencies)))

    def protect_descriptors(self, files, sections, checkout, path):
        # A Git branch change could overwrite/delete a tracked descriptor before
        # its own no-clobber action. Preserve selected existing descriptors too.
        selected = sections.get('vscode-workspaces', [])
        if not selected:
            return
        tracked = self.run(path, 'ls-files', '-z').split(b'\0')
        for workspace in contract.objects(files[contract.VSCODE])['items']:
            relative = contract.portable(workspace['path'])
            if workspace['item_id'] not in selected or not contract.within(relative, checkout):
                continue
            suffix = relative[len(checkout) + 1:]
            if suffix.encode() not in tracked:
                continue
            parent, _, name = relative.rpartition('/')
            if self.destination(parent) is None:
                continue
            with directory_fd(self.home, parent) as directory:
                try:
                    os.stat(name, dir_fd=directory, follow_symlinks=False)
                except FileNotFoundError:
                    continue
            raise Conflict('workspace_descriptor_conflict')

    def files(self, path, data):
        def check_deadline():
            if time.monotonic() >= self.deadline:
                raise discovery.ObservationError('workspace_observation_failed')

        def identity(info):
            return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)

        check_deadline()
        if data and not data.endswith(b'\0'):
            raise discovery.ObservationError('workspace_observation_failed')
        names = [value.decode('utf-8') for value in data.split(b'\0') if value]
        if len(names) > 4096:
            raise contract.Unsupported('workspace_file_count_limit')
        for name in names:
            check_deadline()
            relative = contract.relative(name.rstrip('/'))
            target = path / relative
            # Check every parent before reading content. Symlinks are not followed.
            discovery.inside(target.parent, self.home)
            try:
                before = target.lstat()
            except FileNotFoundError:
                self.remember([relative, 'absent'])  # A tracked deletion is dirty.
                continue
            self.remember([relative, before.st_dev, before.st_ino, before.st_mode, before.st_size,
                           before.st_mtime_ns, before.st_ctime_ns])
            if stat.S_ISLNK(before.st_mode):
                raise contract.Unsupported('workspace_symlink_unsupported')
            if stat.S_ISDIR(before.st_mode):
                continue  # A nested checkout; never traverse it implicitly.
            if not stat.S_ISREG(before.st_mode):
                raise contract.Unsupported('workspace_file_unsupported')
            self.bytes_read += before.st_size
            if self.bytes_read > 16 * 1024 * 1024:
                raise contract.Unsupported('workspace_file_bytes_limit')
            check_deadline()
            # A regular file can become a FIFO after lstat. Never block in open,
            # and never read a replacement before qualifying the actual FD.
            descriptor = os.open(target, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            try:
                opened = os.fstat(descriptor)
                if not stat.S_ISREG(opened.st_mode):
                    raise contract.Unsupported('workspace_file_unsupported')
                if identity(before) != identity(opened):
                    raise discovery.ObservationError('workspace_observation_changed')
                content = hashlib.sha256()
                total = 0
                while True:
                    check_deadline()
                    chunk = os.read(descriptor, min(65536, before.st_size - total + 1))
                    check_deadline()
                    total += len(chunk)
                    if total > before.st_size:
                        raise discovery.ObservationError('workspace_observation_changed')
                    if not chunk:
                        break
                    content.update(chunk)
                after = os.fstat(descriptor)
            finally:
                os.close(descriptor)
            check_deadline()
            if total != before.st_size or identity(opened) != identity(after) or identity(target.lstat()) != identity(before):
                raise discovery.ObservationError('workspace_observation_changed')
            self.remember(content.hexdigest())
        check_deadline()
        return names

    def require_inert_hooks(self, path, common=None):
        # No hook suppression is promised by Phase 3. Includes/overrides are
        # unqualified; do not follow their paths or execute a hook to inspect it.
        pattern = r'^(core\.hookspath|hook\.|include\.|includeif\.|init\.templatedir)'
        template_override = 'GIT_TEMPLATE_DIR' in os.environ
        self.remember(template_override)
        if template_override:
            raise contract.Unsupported('workspace_hooks_unsupported')
        if self.run(path, 'config', '--no-includes', '--get-regexp', pattern, absent=True, hook_config=True):
            raise contract.Unsupported('workspace_hooks_unsupported')
        if common is None:
            return
        directory = common / 'hooks'
        try:
            info = directory.lstat()
        except FileNotFoundError:
            self.remember('hooks_absent')
            return
        self.remember([info.st_dev, info.st_ino, info.st_mode])
        if not stat.S_ISDIR(info.st_mode):
            raise contract.Unsupported('workspace_hooks_unsupported')
        if not os.access(directory, os.R_OK | os.X_OK):
            raise PermissionError()
        for name in ('post-checkout', 'post-index-change', 'reference-transaction'):
            hook = directory / name
            try:
                info = hook.lstat()
            except FileNotFoundError:
                self.remember([name, 'absent'])
                continue
            self.remember([name, info.st_dev, info.st_ino, info.st_mode, info.st_size,
                           info.st_mtime_ns, info.st_ctime_ns])
            if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o111 or os.access(hook, os.X_OK):
                raise contract.Unsupported('workspace_hooks_unsupported')

    def mutation_metadata(self, path, common):
        """Qualify metadata Git may write; never follow redirected refs/logs/index."""
        gitdir = Path(self.line(path, 'rev-parse', '--absolute-git-dir'))
        count = 0
        for directory in sorted({common, gitdir}):
            for name in ('index', 'HEAD', 'config', 'packed-refs', 'shallow', 'refs', 'logs', 'worktrees'):
                root = directory / name
                pending = [root]
                while pending:
                    target = pending.pop()
                    count += 1
                    if count > 4096 or time.monotonic() >= self.deadline:
                        raise contract.Unsupported('workspace_git_metadata_unsupported')
                    try:
                        info = target.lstat()
                    except FileNotFoundError:
                        self.remember([str(target), 'absent'])
                        continue
                    self.remember([str(target), info.st_dev, info.st_ino, info.st_mode,
                                   info.st_size, info.st_mtime_ns, info.st_ctime_ns])
                    if stat.S_ISDIR(info.st_mode):
                        pending.extend(sorted(target.iterdir()))
                    elif not stat.S_ISREG(info.st_mode):
                        raise contract.Unsupported('workspace_git_metadata_unsupported')
                    if target.name.endswith('.lock') or target.name == 'locked':
                        raise Conflict('workspace_operation_in_progress')

    def clone_profile(self, remote, destination, branch):
        from clone_execution import command, ssh_configuration
        try:
            with ExitStack() as scratch:
                ssh = remote.startswith('ssh://') or (':' in remote and not remote.startswith('https://'))
                configuration = ssh_configuration(scratch) if ssh else '/dev/null'
                command(remote, str(destination), branch, configuration,
                        observe=lambda data: self.remember(hashlib.sha256(data).hexdigest()))
        except (OSError, ValueError):
            raise contract.Unsupported('workspace_configuration_unsupported') from None

    def checkout(self, path):
        common = self.common(path)
        unsafe = self.run(path, 'config', '--local', '--no-includes', '--name-only', '--get-regexp',
            r'^(core\.(worktree|sparsecheckout|splitindex)|extensions\.|submodule\.|include|filter\.)', absent=True)
        if unsafe or (common / 'objects/info/http-alternates').exists():
            raise contract.Unsupported('workspace_configuration_unsupported')
        gitdir = Path(self.line(path, 'rev-parse', '--absolute-git-dir'))
        discovery.inside(gitdir, self.home)
        in_progress = any(os.path.lexists(directory / name) for directory in {gitdir, common} for name in (
            'index.lock', 'HEAD.lock', 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD',
            'rebase-merge', 'rebase-apply', 'sequencer', 'packed-refs.lock', 'config.lock', 'shallow.lock'))
        in_progress |= any(common.glob('refs/**/*.lock'))
        self.remember(in_progress)
        entries = discovery.porcelain(self.run(path, 'worktree', 'list', '--porcelain', '-z'))
        origin = self.line(path, 'config', '--local', '--no-includes', '--get', 'remote.origin.url', absent=True)
        oid = self.line(path, 'rev-parse', '--verify', 'HEAD^{commit}')
        branch = self.line(path, 'symbolic-ref', '--quiet', 'HEAD', absent=True)
        own = [entry for entry in entries if entry['path'] == str(path)]
        if len(own) != 1 or own[0].get('HEAD') != oid or own[0].get('branch', '') != branch:
            raise discovery.ObservationError('workspace_observation_changed')
        if any(key in own[0] for key in ('locked', 'prunable', 'bare')):
            raise Conflict('workspace_topology_conflict')
        index = self.run(path, 'ls-files', '--stage', '-z')
        if any(row.startswith(b'160000 ') for row in index.split(b'\0')):
            raise contract.Unsupported('workspace_submodule_unsupported')
        flags = self.run(path, 'ls-files', '-v', '-z')
        if any(row and not row.startswith(b'H ') for row in flags.split(b'\0')):
            # assume-unchanged / skip-worktree can hide tracked edits from status.
            raise contract.Unsupported('workspace_index_unsupported')
        status = self.run(path, 'status', '--porcelain=v1', '-z', '--untracked-files=no', '--ignore-submodules=none')
        return dict(common=common, entries=entries, origin=origin, oid=oid, branch=branch,
                    dirty=bool(status), protected=None, in_progress=in_progress)

    def desired(self, path, record, member, observed, *, creating=False):
        if member['head_kind'] == 'branch':
            branch = record['branch']
            if any(row.get('branch') == 'refs/heads/' + branch and
                   (creating or row['path'] != str(path)) for row in observed['entries']):
                return 'inspect', 'conflict', 'workspace_branch_occupied'
            target = self.line(path, 'rev-parse', '--verify', '--quiet', 'refs/heads/' + branch + '^{commit}', absent=True)
            if not target:
                return 'inspect', 'blocked', 'workspace_branch_unavailable'
            matches = observed['branch'] == 'refs/heads/' + branch
        else:
            target = self.line(path, 'rev-parse', '--verify', '--quiet', member['head_oid'] + '^{commit}', absent=True)
            if target != member['head_oid']:
                return 'inspect', 'blocked', 'workspace_commit_unavailable'
            matches = not observed['branch'] and observed['oid'] == member['head_oid']
        if matches and not creating:
            return 'none', 'satisfied', 'workspace_local_changes_preserved' if observed['dirty'] else None
        if observed['in_progress']:
            return 'inspect', 'blocked', 'workspace_operation_in_progress'
        self.require_inert_hooks(path, observed['common'])
        self.mutation_metadata(path, observed['common'])
        # Matching checkout metadata implies no Git action: project contents,
        # ignored build products and content symlinks cannot obstruct that no-op.
        # Potential actions still require the complete bounded file evidence.
        self.files(path, self.run(path, 'ls-files', '-z'))
        protected = self.files(path, self.run(path, 'ls-files', '--others', '--exclude-standard', '-z'))
        protected += self.files(path, self.run(path, 'ls-files', '--others', '--ignored', '--exclude-standard', '-z'))
        if not creating:
            observed['protected'] = protected
        if observed['dirty'] and not creating:
            return 'inspect', 'conflict', 'workspace_local_changes'
        tree = self.run(path, 'ls-tree', '-r', '-z', target)
        destinations = []
        for row in tree.split(b'\0'):
            if not row:
                continue
            mode, name = row.split(b'\t', 1)
            if mode.startswith((b'160000 ', b'120000 ')):
                raise contract.Unsupported('workspace_tree_unsupported')
            destinations.append(contract.relative(name.decode('utf-8')))
        if creating:
            return 'add_worktree', 'planned', None
        if any(related(name, destination) for name in observed['protected'] for destination in destinations):
            return 'inspect', 'conflict', 'workspace_protected_files'
        return 'switch_branch', 'planned', None

    def plan(self, files):
        sections, _ = bundle.parse_blueprint(files['blueprint.conf'])
        records = contract.repository_records(files[contract.REPOSITORIES]) if contract.TOPOLOGY in files else {}
        topology = contract.objects(files[contract.TOPOLOGY]) if contract.TOPOLOGY in files else {'groups': []}
        selected = sections['git-repositories']
        if selected and contract.TOPOLOGY not in files:
            raise bundle.Unsupported('Selected Git checkouts require topology metadata alongside descriptors')
        paths = {item: contract.portable(row['path'], self.source_home) for item, row in records.items()}
        members = {member['item_id']: (group, member) for group in topology['groups'] for member in group['members']}
        capability = contract.detect_worktree_capability(cwd=self.home, repository_independent=True) if selected else {'status': 'supported'}
        self.remember(capability)
        if selected and capability['status'] == 'supported':
            self.git = contract.git_executable()
        result, completed = [], {}
        pending = set(selected)
        dependencies = {item: ({members[item][0]['base_item_id']} - {item}) |
                        {other for other in selected if other != item and contract.within(paths[item], paths[other])}
                        for item in selected}
        while pending:
            ready = sorted(item for item in pending if not dependencies[item] & pending)
            if not ready:
                raise contract.Invalid('cyclic selected topology')
            for item in ready:
                row = records[item]
                group, member = members[item]
                base = group['base_item_id']
                action, disposition, reason = 'inspect', 'unknown', 'workspace_observation_failed'
                observation = None
                try:
                    path = self.destination(paths[item])
                    from clone_execution import pending as partial_pending
                    if partial_pending(self.home / paths[item]):
                        raise Conflict('workspace_partial_checkout')
                    if capability['status'] != 'supported':
                        raise contract.Unsupported('workspace_git_unsupported')
                    if member['head_kind'] == 'branch':
                        self.run(self.home, 'check-ref-format', '--branch', row['branch'])
                    if any(completed[parent]['disposition'] not in ('satisfied', 'planned') for parent in dependencies[item]):
                        action, disposition, reason = 'inspect', 'blocked', 'workspace_dependency_pending'
                    elif ((path is None or not any(path.iterdir())) and
                          any(completed[parent]['disposition'] == 'planned' for parent in dependencies[item])):
                        action, disposition, reason = ('clone' if item == base else 'add_worktree'), 'planned', 'workspace_dependency_pending'
                    elif path is None or not any(path.iterdir()):
                        if item == base:
                            self.require_inert_hooks(self.home)
                            self.clone_profile(row['remote'], self.home / paths[item], row['branch'])
                            action, disposition, reason = 'clone', 'planned', (
                                None if member['head_kind'] == 'branch' else 'workspace_commit_after_clone')
                        else:
                            base_observation = completed[base]['observation']
                            if any(entry['path'] == str(self.home / paths[item]) for entry in base_observation['entries']):
                                raise Conflict('workspace_topology_conflict')
                            action, disposition, reason = self.desired(self.home / paths[base], row, member, base_observation, creating=True)
                    else:
                        if not os.path.lexists(path / '.git'):
                            raise Conflict('workspace_destination_conflict')
                        observation = self.checkout(path)
                        if self.line(path, 'rev-parse', '--show-object-format') != group['object_format']:
                            raise Conflict('workspace_topology_conflict')
                        expected_common = self.home / paths[base] / '.git'
                        if observation['common'] != expected_common or observation['entries'][0]['path'] != str(self.home / paths[base]):
                            raise Conflict('workspace_topology_conflict')
                        if observation['origin'] != row['remote']:
                            raise Conflict('workspace_origin_conflict')
                        action, disposition, reason = self.desired(path, row, member, observation)
                        if action == 'switch_branch' and disposition == 'planned':
                            self.protect_descriptors(files, sections, paths[item], path)
                except Conflict as exc:
                    action, disposition, reason = 'inspect', 'conflict', str(exc)
                except contract.Unsupported as exc:
                    action, disposition, reason = 'inspect', 'blocked', UNSUPPORTED_REASONS.get(str(exc), 'workspace_git_unsupported')
                except (OSError, ValueError, subprocess.SubprocessError) as exc:
                    if getattr(exc, 'quiescent', True) is False:
                        raise
                    action, disposition, reason = 'inspect', 'unknown', 'workspace_observation_failed'
                planned = dict(domain='git-repositories', item_id=str(selected.index(item) + 1),
                               action=action, disposition=disposition, reason=reason,
                               checkout_id=item, checkout_role='base' if base == item else 'linked',
                               head_kind=member['head_kind'], dependency_ids=sorted(dependencies[item]))
                if re.fullmatch(r'[\w .-]{1,128}', row['name']):
                    planned['display_name'] = row['name']
                if observation is not None:
                    planned['local_changes'] = observation['dirty']
                    if observation['protected'] is not None:
                        planned['protected_files'] = bool(observation['protected'])
                completed[item] = dict(planned, observation=observation)
                result.append(planned)
                pending.remove(item)
        for folder in sections['workspace-folders']:
            shared = next((completed[item] for item in selected if paths[item] == folder), None)
            parents = [item for item in selected if contract.within(folder, paths[item])]
            if shared is not None:
                try:
                    exists = self.destination(folder) is not None
                    # Folder structure already matches independently of any Git
                    # blocker. Absent shared destinations still belong to Git;
                    # never precreate them or bypass checkout dependencies.
                    action, disposition, reason = 'none', 'satisfied' if exists else shared['disposition'], 'workspace_checkout_destination'
                    if disposition not in ('planned', 'satisfied'):
                        reason = shared['reason']
                except Conflict:
                    action, disposition, reason = 'inspect', 'conflict', 'workspace_destination_conflict'
                except OSError:
                    action, disposition, reason = 'inspect', 'unknown', 'workspace_observation_failed'
            else:
                try:
                    exists = self.destination(folder) is not None
                    if any(completed[parent]['disposition'] not in ('satisfied', 'planned') for parent in parents):
                        action, disposition, reason = 'inspect', 'blocked', 'workspace_dependency_pending'
                    else:
                        action, disposition, reason = ('none', 'satisfied', None) if exists else ('create_directory', 'planned', None)
                        if not exists and any(completed[parent]['disposition'] == 'planned' for parent in parents):
                            reason = 'workspace_dependency_pending'
                except Conflict:
                    action, disposition, reason = 'inspect', 'conflict', 'workspace_destination_conflict'
                except OSError:
                    action, disposition, reason = 'inspect', 'unknown', 'workspace_observation_failed'
            result.append(dict(domain='workspace-folders', item_id=folder, action=action, disposition=disposition,
                               reason=reason, dependency_ids=sorted(parents)))
        self.workspaces(files, paths, result)
        return result


def inspect(files, home, reader):
    """Two complete observations must agree; expose only typed rows and a digest."""
    deadline = time.monotonic() + 120
    before, after = Inspector(home, reader, deadline), Inspector(home, reader, deadline)
    first = before.plan(files)
    second = after.plan(files)
    if first != second or before.evidence.digest() != after.evidence.digest():
        for row in second:
            row.update(action='inspect', disposition='unknown', reason='workspace_observation_changed')
    return {'plan': second, 'fingerprint': after.evidence.hexdigest()}
