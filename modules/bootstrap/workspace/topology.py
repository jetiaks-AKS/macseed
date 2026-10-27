"""Workspace metadata contract only. No Discovery, publication or Git mutation.

Sectional repository values come from the production Config Engine bridge.
Bundle archive/Blueprint parsing stays in modules/bundle/bundle.py.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unicodedata
from urllib.parse import urlsplit

TOPOLOGY = 'generated/workspace/topology.json'
VSCODE = 'generated/workspace/vscode-workspaces.json'
REPOSITORIES = 'generated/workspace/repositories.conf'
MAX_BYTES = 1024 * 1024
MAX_ITEMS = 2048
FEATURES = {TOPOLOGY: 'workspace-topology', VSCODE: 'vscode-workspaces'}
BRIDGE = Path(__file__).with_name('topology-input.sh')


class Invalid(ValueError):
    pass


class Unsupported(Invalid):
    pass


class SelectionInvalid(Invalid):
    """Fixed public codes only; never attach paths or repository values."""
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def text(value, limit=4096, empty=False):
    if (not isinstance(value, str) or len(value.encode('utf-8')) > limit or
            (not value and not empty) or any(ord(c) < 32 or ord(c) == 127 for c in value)):
        raise Invalid('invalid Workspace text')
    return value


def relative(value):
    text(value)
    if (value.startswith(('~', '/')) or '\\' in value or
            any(p in ('', '.', '..') or p.casefold() == '.git' for p in value.split('/'))):
        raise Invalid('unsafe HOME-relative Workspace path')
    return value


def portable(value, home=None):
    text(value)
    if value.startswith('~/'):
        return relative(value[2:])
    if home is not None and value.startswith(str(home).rstrip('/') + '/'):
        return relative(value[len(str(home).rstrip('/')) + 1:])
    raise Invalid('nonportable Workspace path')


def identity(kind, path):
    if kind not in ('checkout', 'repository', 'workspace'):
        raise Invalid('invalid Workspace identity kind')
    path = unicodedata.normalize('NFC', relative(path))
    return kind + '-' + hashlib.sha256((kind + '\0' + path).encode()).hexdigest()


def keys(value, required, optional=()):
    if not isinstance(value, dict) or not set(required) <= set(value) or set(value) - set(required) - set(optional):
        raise Invalid('invalid Workspace metadata fields')


def objects(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise Invalid('duplicate Workspace JSON key')
            result[key] = value
        return result
    def invalid_number(_):
        raise Invalid('invalid JSON number')
    if not isinstance(data, bytes) or len(data) > MAX_BYTES:
        raise Invalid('oversized Workspace metadata')
    try:
        value = json.loads(data, object_pairs_hook=unique, parse_constant=invalid_number)
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise Invalid('invalid Workspace JSON') from exc
    if not isinstance(value, dict) or type(value.get('contract')) is not int or value['contract'] != 1:
        raise Unsupported('unsupported Workspace metadata version')
    return value


def rows(value, *, empty=False):
    if not isinstance(value, list) or len(value) > MAX_ITEMS or (not value and not empty):
        raise Invalid('invalid Workspace item list')
    return value


def aliases(paths):
    seen = set()
    for path in paths:
        key = unicodedata.normalize('NFC', relative(path)).casefold()
        if key in seen:
            raise Invalid('overlapping or aliased Workspace destinations')
        seen.add(key)


def within(path, parent):
    path, parent = (unicodedata.normalize('NFC', value).casefold() for value in (path, parent))
    return path == parent or path.startswith(parent + '/')


def target_paths(paths, home, file_paths=()):
    """Optional read-only target admission; never infer absence after an error."""
    root = Path(home).resolve(strict=True)
    seen = set()
    for path in paths:
        current = root
        parts = relative(path).split('/')
        for index, part in enumerate(parts):
            if not os.access(current, os.R_OK | os.X_OK):
                raise Invalid('Workspace ancestor is unavailable')
            current = current / part
            try:
                info = current.lstat()
            except FileNotFoundError:
                break
            leaf = index == len(parts) - 1
            if stat.S_ISLNK(info.st_mode):
                raise Invalid('Workspace symlink alias is unsupported')
            if not stat.S_ISDIR(info.st_mode) and not (leaf and path in file_paths and stat.S_ISREG(info.st_mode)):
                raise Invalid('Workspace path type conflict')
            if leaf:
                key = (info.st_dev, info.st_ino)
                if key in seen:
                    raise Invalid('Workspace filesystem alias')
                seen.add(key)


def repository_input(data, selected=None):
    if len(data) > MAX_BYTES or b'\0' in data:
        raise Invalid('invalid repository metadata size or encoding')
    # Temporary input is private and is never sourced/evaluated as shell code.
    with tempfile.TemporaryDirectory(prefix='macseed-topology-') as directory:
        path = Path(directory) / 'repositories.conf'
        path.write_bytes(data)
        path.chmod(0o600)
        environment = {k: v for k, v in os.environ.items() if k not in ('BASH_ENV', 'ENV', 'CDPATH')}
        result = subprocess.run(['/bin/bash', str(BRIDGE), str(path),
                                 'topology' if selected is None else 'select'],
                                input=None if selected is None else ('\n'.join(sorted(selected)) + '\n').encode(),
                                capture_output=True, timeout=30, env=dict(environment, LC_ALL='C'))
    if result.returncode or len(result.stdout) > MAX_BYTES:
        raise Invalid('invalid sectional topology repository records')
    return result.stdout


def repository_records(data):
    fields = repository_input(data).decode('utf-8').split('\0')
    if fields.pop() != '' or len(fields) % 7 or len(fields) // 7 > MAX_ITEMS:
        raise Invalid('invalid repository reader output')
    records = {}
    for offset in range(0, len(fields), 7):
        item, name, path, remote, branch, default_branch, version = fields[offset:offset + 7]
        if item in records or version != '1':
            raise Invalid('ambiguous repository schema')
        for value in (name, path, remote):
            text(value)
            if '"' in value:
                raise Invalid('ambiguous repository value')
        text(branch, empty=True)
        text(default_branch, empty=True)
        if default_branch:
            branch_metadata_valid(default_branch)
        records[item] = dict(name=name, path=path, remote=remote, branch=branch)
    return records


def remote_valid(remote):
    if remote != remote.strip() or remote.startswith('-') or any(c in remote for c in ('?', '#', '\\')):
        raise Invalid('unsafe repository origin')
    if '://' in remote:
        value = urlsplit(remote)
        if value.scheme not in ('https', 'http', 'ssh') or not value.hostname or not value.path.strip('/'):
            raise Unsupported('nonportable repository origin')
        if value.port is not None and not 0 < value.port <= 65535:
            raise Invalid('invalid repository origin port')
        if value.password is not None or (value.username is not None and
                (value.scheme != 'ssh' or not re.fullmatch(r'[A-Za-z0-9._-]+', value.username))):
            raise Invalid('credential-bearing repository origin')
    elif not re.fullmatch(r'(?:[A-Za-z0-9._-]+@)?[A-Za-z0-9.-]+:[^\s:]+', remote):
        raise Unsupported('nonportable repository origin')


def branch_metadata_valid(branch):
    """Static literal branch syntax; never expand shorthand or invoke Git.

    Git check-ref-format rules plus the existing sectional quote restriction.
    Native branch_valid remains a separate prerequisite for future operations.
    """
    text(branch)
    if (branch in ('HEAD', '@') or branch.startswith('-') or branch.endswith('.') or
            '..' in branch or '@{' in branch or any(c in branch for c in ' ~^:?*[\\"') or
            any(not part or part.startswith('.') or part.endswith('.lock') for part in branch.split('/'))):
        raise Invalid('invalid named branch')


def branch_valid(branch):
    """Native readiness check, intentionally separate from Bundle validation."""
    branch_metadata_valid(branch)
    result = subprocess.run([git_executable(), 'check-ref-format', '--branch', branch],
                            capture_output=True, timeout=10)
    if result.returncode or result.stdout.decode().rstrip('\n') != branch:
        raise Invalid('invalid named branch')


def git_executable(git='git'):
    executable = shutil.which(git)
    if executable is None:
        raise Unsupported('Git is unavailable for Workspace validation')
    # Match the existing repository readiness boundary: do not invoke Apple's
    # install-prompting shim without an already selected developer directory.
    if executable == '/usr/bin/git':
        result = subprocess.run(['xcode-select', '-p'], capture_output=True, timeout=10)
        if result.returncode:
            raise Unsupported('Git developer tools are unavailable')
    return executable


def selection(values):
    if not isinstance(values, list) or any(not isinstance(v, str) for v in values) or len(values) != len(set(values)):
        raise Invalid('invalid Workspace selection')
    return set(values)


def validate(files, sections, *, home=None, exact=False, inspect_home=False):
    """Validate a full staged inventory or an exact selected Bundle projection."""
    selected = selection(sections.get('git-repositories', []))
    selected_workspaces = selection(sections.get('vscode-workspaces', []))
    selected_folders = selection(sections.get('workspace-folders', []))
    marked = re.search(rb'^TOPOLOGY_VERSION=', files.get(REPOSITORIES, b''), re.M) is not None
    if marked != (TOPOLOGY in files):
        raise Invalid('topology marker and metadata must be paired')
    if bool(selected_workspaces) and VSCODE not in files:
        raise Invalid('selected VS Code workspace metadata missing')
    features = {feature: 1 for path, feature in FEATURES.items() if path in files}
    if not features:
        return features
    destinations, repository_paths, dependencies = [], {}, {}
    if TOPOLOGY in files:
        topology = objects(files[TOPOLOGY])
        keys(topology, ('contract', 'roots', 'groups'))
        roots = [relative(root) for root in rows(topology['roots'])]
        if len(roots) > 64:
            raise Invalid('too many Workspace roots')
        aliases(roots)
        records = repository_records(files[REPOSITORIES])
        for item, record in records.items():
            path = portable(record['path'], home)
            if item != identity('checkout', path) or not any(within(path, root) for root in roots):
                raise Invalid('repository identity or discovery root mismatch')
            remote_valid(record['remote'])
            repository_paths[item] = path
        groups, members = set(), set()
        for group in rows(topology['groups']):
            keys(group, ('id', 'base_item_id', 'object_format', 'members'))
            base = text(group['base_item_id'])
            if base not in records or group['id'] != identity('repository', repository_paths[base]) or group['id'] in groups:
                raise Invalid('invalid or missing topology base')
            groups.add(group['id'])
            if group['object_format'] not in ('sha1', 'sha256'):
                raise Unsupported('unsupported Git object format')
            group_members = set()
            branches = set()
            for member in rows(group['members']):
                keys(member, ('item_id', 'head_kind', 'head_oid'))
                item = text(member['item_id'])
                if item not in records or item in members:
                    raise Invalid('invalid or duplicate topology member')
                members.add(item)
                group_members.add(item)
                record = records[item]
                if record['remote'] != records[base]['remote']:
                    raise Invalid('inconsistent origins in topology group')
                oid = text(member['head_oid'], 64)
                length = 40 if group['object_format'] == 'sha1' else 64
                if not re.fullmatch('[0-9a-f]{' + str(length) + '}', oid) or set(oid) == {'0'}:
                    raise Invalid('invalid Git HEAD object ID')
                if member['head_kind'] == 'branch':
                    branch_metadata_valid(record['branch'])
                    if record['branch'] in branches:
                        raise Invalid('branch occupied by multiple selected worktrees')
                    branches.add(record['branch'])
                elif member['head_kind'] != 'detached' or record['branch']:
                    raise Invalid('HEAD kind and CURRENT_BRANCH disagree')
                dependencies[item] = {base} if item != base else set()
            if base not in group_members:
                raise Invalid('base is not a member of its group')
        if members != set(records) or not selected <= members or (exact and selected != members):
            raise Invalid('repository records, topology and selection disagree')
        aliases(repository_paths.values())
        # Nested checkouts are representable, but both the parent checkout and
        # the common-repository base must be explicit selected dependencies.
        for item, path in repository_paths.items():
            dependencies[item].update(other for other, parent in repository_paths.items()
                                      if other != item and within(path, parent))
        pending = {item: set(deps) for item, deps in dependencies.items()}
        while pending:
            ready = {item for item, deps in pending.items() if not deps & pending.keys()}
            if not ready:
                raise Invalid('cyclic Workspace path/base dependencies')
            pending = {item: deps for item, deps in pending.items() if item not in ready}
        if any(not dependencies[item] <= selected for item in selected):
            raise SelectionInvalid('workspace_dependency_missing')
    selected_repository_paths = {path for item, path in repository_paths.items() if item in selected}
    destinations.extend(selected_repository_paths)
    folder_paths = {}
    for line in files.get('generated/workspace/folders.conf', b'').decode().splitlines():
        parts = line.split('|')
        if len(parts) != 2 or parts[1] not in ('workspace', 'user', 'system'):
            raise Invalid('invalid Workspace folders')
        if parts[0] in folder_paths:
            raise Invalid('duplicate Workspace folder')
        folder_paths[relative(parts[0])] = parts[1]
    if not selected_folders <= folder_paths.keys():
        raise Invalid('selected Workspace folder missing')
    folder_destinations = [path for path in selected_folders if folder_paths[path] == 'workspace']
    if len(folder_destinations) != len(selected_folders):
        raise Invalid('selected folder is not a Workspace folder')
    # Structure alone never selects a checkout. Exact path equality is two roles
    # of one destination; keep both records, but inspect the destination once.
    # Do not fold case/Unicode aliases or deduplicate within either role.
    destinations.extend(path for path in folder_destinations if path not in selected_repository_paths)
    workspace_paths = []
    relationship_paths = set()
    if VSCODE in files:
        workspaces = objects(files[VSCODE])
        keys(workspaces, ('contract', 'items'))
        ids = set()
        for workspace in rows(workspaces['items']):
            keys(workspace, ('item_id', 'path', 'folders'))
            path = portable(workspace['path'])
            item = text(workspace['item_id'])
            if item != identity('workspace', path) or item in ids or not path.endswith('.code-workspace'):
                raise Invalid('invalid VS Code workspace identity')
            ids.add(item)
            targets = []
            for folder in rows(workspace['folders']):
                keys(folder, ('domain', 'item_id', 'subpath'), ('name',))
                if 'name' in folder:
                    text(folder['name'], 160)
                domain, target = folder['domain'], text(folder['item_id'])
                suffix = relative(folder['subpath']) if folder['subpath'] != '' else ''
                if domain == 'git-repositories' and target in repository_paths:
                    destination = repository_paths[target]
                    chosen = selected
                elif domain == 'workspace-folders' and folder_paths.get(target) == 'workspace':
                    destination = target
                    chosen = selected_folders
                else:
                    raise Invalid('unresolved VS Code folder relationship')
                if item in selected_workspaces and target not in chosen:
                    raise SelectionInvalid('workspace_dependency_missing')
                targets.append(destination + ('/' + suffix if suffix else ''))
            if item in selected_workspaces:
                relationship_paths.update(targets)
            aliases(targets)
            if item in selected_workspaces:
                if any(within(path, parent) and repo not in selected for repo, parent in repository_paths.items()):
                    raise SelectionInvalid('workspace_dependency_missing')
                workspace_paths.append(path)
        if not selected_workspaces <= ids or (exact and selected_workspaces != ids):
            raise Invalid('VS Code workspace inventory and selection disagree')
        destinations.extend(workspace_paths)
    try:
        aliases(folder_destinations)
        aliases(destinations)
    except Invalid as exc:
        raise SelectionInvalid('workspace_path_conflict') from exc
    if any(other != path and within(other, path) for path in workspace_paths for other in destinations):
        raise Invalid('Workspace descriptor cannot be a parent directory')
    if inspect_home:
        if home is None:
            raise Invalid('target HOME required')
        target_paths(destinations, home, workspace_paths)
        target_paths(relationship_paths, home)
    return features


def selected_payload(files, sections):
    """Called after full validation; reduce relationships without adding scope."""
    if TOPOLOGY in files:
        topology = objects(files[TOPOLOGY])
        chosen = selection(sections.get('git-repositories', []))
        groups = []
        for group in topology['groups']:
            members = [row for row in group['members'] if row['item_id'] in chosen]
            if members:
                if group['base_item_id'] not in chosen:
                    raise Invalid('base checkout must be explicitly selected')
                groups.append(dict(group, members=members))
        if groups:
            records = repository_input(files[REPOSITORIES], chosen)
            files[TOPOLOGY] = (json.dumps(dict(topology, groups=groups), sort_keys=True) + '\n').encode()
            files[REPOSITORIES] = records
        else:
            files.pop(TOPOLOGY)
            files.pop(REPOSITORIES)
    if VSCODE in files:
        workspaces = objects(files[VSCODE])
        items = [row for row in workspaces['items'] if row['item_id'] in sections.get('vscode-workspaces', [])]
        if items:
            files[VSCODE] = (json.dumps(dict(workspaces, items=items), sort_keys=True) + '\n').encode()
        else:
            files.pop(VSCODE)


def validate_legacy_cli(config_file, home, selected):
    """Admit the existing ordinary-repository consumer, never plan topology Apply."""
    if any(os.environ.get(key) == 'true' for key in
           ('BUNDLE_RESTORE_ACTIVE', 'BUNDLE_RESTORE_PREVIEW', 'MACSEED_APPLICATION_EXECUTION')):
        raise Unsupported('topology Restore is not enabled')
    config_file = Path(config_file)
    files = {}
    for name, path in ((REPOSITORIES, config_file), (TOPOLOGY, config_file.with_name('topology.json'))):
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_BYTES:
            raise Invalid('unsafe topology input')
        files[name] = path.read_bytes()
    validate(files, {'git-repositories': selected}, home=home)
    chosen = selection(selected)
    for group in objects(files[TOPOLOGY])['groups']:
        if not chosen.intersection(member['item_id'] for member in group['members']):
            continue
        if len(group['members']) != 1 or group['members'][0]['head_kind'] != 'branch':
            raise Unsupported('linked/shared worktrees and detached HEAD require topology Restore')
    records = repository_records(files[REPOSITORIES])
    paths = [portable(records[item]['path'], home) for item in chosen]
    target_paths(paths, home)
    for relative_path in paths:
        marker = Path(home) / relative_path / '.git'
        try:
            info = marker.lstat()
        except FileNotFoundError:
            continue  # Existing legacy inspection distinguishes missing and non-Git destinations.
        if not stat.S_ISDIR(info.st_mode):
            raise Unsupported('linked or indirect Git directory requires topology Restore')
        # Reject a checkout that became shared since Discovery, without invoking Git mutation.
        for name in ('commondir', 'worktrees'):
            path = marker / name
            try:
                info = path.lstat()
            except FileNotFoundError:
                continue
            if name == 'commondir' or not stat.S_ISDIR(info.st_mode) or any(path.iterdir()):
                raise Unsupported('shared Git directory requires topology Restore')


def detect_worktree_capability(git='git', *, cwd=None):
    """Read-only option probe; the Discovery parser validates the actual bytes."""
    environment = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    environment.update(LC_ALL='C', GIT_OPTIONAL_LOCKS='0', GIT_CONFIG_NOSYSTEM='1',
                       GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null')
    try:
        git = git_executable(git)
        location = {} if cwd is None else {'cwd': cwd}
        before = subprocess.run([git, '--version'], capture_output=True, timeout=10, env=environment, **location)
        help_result = subprocess.run([git, 'worktree', 'list', '-h'], capture_output=True,
                                     timeout=10, env=environment, **location)
        after = subprocess.run([git, '--version'], capture_output=True, timeout=10, env=environment, **location)
        if before.returncode or after.returncode or not re.fullmatch(rb'git version [0-9]+\.[0-9]+[^\r\n]*\n?', before.stdout):
            reason = 'git_version_unavailable'
        elif before.stdout != after.stdout:
            reason = 'git_version_changed'
        elif (help_result.returncode not in (0, 129) or
              b'--porcelain' not in help_result.stdout + help_result.stderr or
              not re.search(rb'(?m)^\s+-z(?:[ ,]|$)', help_result.stdout + help_result.stderr)):
            reason = 'worktree_porcelain_z_unavailable'
        else:
            return {'status': 'supported', 'reason': 'worktree_porcelain_z'}
    except (Unsupported, OSError, subprocess.SubprocessError):
        reason = 'git_observation_failed'
    return {'status': 'unsupported', 'reason': reason}


if __name__ == '__main__':
    try:
        if len(sys.argv) != 4 or sys.argv[1] != '--legacy-cli':
            raise Invalid('invalid topology validation command')
        selected = sys.stdin.buffer.read(MAX_BYTES + 1)
        if len(selected) > MAX_BYTES:
            raise Invalid('oversized selection')
        validate_legacy_cli(sys.argv[2], sys.argv[3], selected.decode().splitlines())
    except Unsupported as exc:
        print('Unsupported Workspace topology in legacy CLI: ' + str(exc), file=sys.stderr)
        sys.exit(2)
    except (Invalid, OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        print('Workspace topology validation failed; no actions permitted', file=sys.stderr)
        sys.exit(2)
