"""Bounded, read-only Workspace observation. Publication stays in workspace.sh."""
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
from urllib.parse import urlsplit, urlunsplit

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('workspace_contract',
    Path(__file__).resolve().parents[2] / 'bootstrap/workspace/topology.py')
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)
MAX_ENTRIES = 50000
COUNTERS = ('UNSUPPORTED_REPOSITORIES', 'MISSING_WORKTREES', 'LOCKED_WORKTREES',
            'PRUNABLE_WORKTREES', 'EXTERNAL_WORKTREES', 'UNSUPPORTED_WORKSPACES',
            'GIT_CAPABILITY_UNSUPPORTED', 'REMOTE_REDACTED')


class ObservationError(ValueError):
    pass


def porcelain(data):
    """Qualified porcelain -z grammar; no C-quoting or line-parser fallback."""
    if not data or len(data) > contract.MAX_BYTES or not data.endswith(b'\0\0'):
        raise contract.Unsupported('worktree_format_unsupported')
    result, paths = [], set()
    for record in data[:-2].split(b'\0\0'):
        fields = record.decode('utf-8').split('\0')
        if not fields[0].startswith('worktree '):
            raise contract.Unsupported('worktree_format_unsupported')
        row = {'path': contract.text(fields[0][9:])}
        if not row['path'].startswith('/') or row['path'] in paths:
            raise contract.Unsupported('worktree_path_ambiguous')
        paths.add(row['path'])
        for field in fields[1:]:
            key, _, value = field.partition(' ')
            if key not in ('HEAD', 'branch', 'detached', 'bare', 'locked', 'prunable') or key in row:
                raise contract.Unsupported('worktree_format_unsupported')
            if key in ('bare', 'detached') and value:
                raise contract.Unsupported('worktree_format_unsupported')
            row[key] = value
        if 'bare' in row:
            if set(row) != {'path', 'bare'}:
                raise contract.Unsupported('worktree_format_unsupported')
        elif ('HEAD' not in row or not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', row['HEAD']) or
              ('branch' in row) == ('detached' in row)):
            raise contract.Unsupported('worktree_format_unsupported')
        elif 'branch' in row:
            if not row['branch'].startswith('refs/heads/'):
                raise contract.Unsupported('worktree_branch_unsupported')
            contract.branch_metadata_valid(row['branch'][11:])
        result.append(row)
    if len(result) > contract.MAX_ITEMS:
        raise contract.Unsupported('worktree_inventory_oversized')
    return result


def read_file(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > contract.MAX_BYTES:
        raise contract.Unsupported('workspace_file_unsupported')
    return path.read_bytes()


def inside(path, home):
    """Reject symlinks at every component before reading a checkout or Git dir."""
    if not path.is_absolute() or '..' in path.parts or '.' in path.parts:
        raise contract.Unsupported('workspace_path_unsupported')
    try:
        parts = path.relative_to(home).parts
    except ValueError as exc:
        raise contract.Unsupported('external_workspace_path') from exc
    current = home
    for part in parts:
        current /= part
        if current.is_symlink():
            raise contract.Unsupported('workspace_symlink_unsupported')
        current.lstat()  # Access errors are observations, never absence.
    return path


class Observer:
    def __init__(self, home, roots):
        self.home = Path(home).resolve(strict=True)
        self.roots = sorted(set(roots))
        contract.aliases(self.roots)
        if len(self.roots) > 64:
            raise contract.Invalid('too_many_workspace_roots')
        self.counts = dict.fromkeys(COUNTERS, 0)
        self.environment = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
        self.environment.update(LC_ALL='C', GIT_OPTIONAL_LOCKS='0', GIT_TERMINAL_PROMPT='0',
            GIT_NO_LAZY_FETCH='1', GIT_CONFIG_NOSYSTEM='1',
            GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null')
        self.git = None

    def run(self, path, *args, absent=False):
        command = [self.git, '-c', 'core.fsmonitor=false', '-c', 'core.untrackedCache=false',
                   '-C', str(path), *args]
        result = subprocess.run(command, env=self.environment, capture_output=True, timeout=15)
        if absent and result.returncode == 1:
            return b''
        if result.returncode or len(result.stdout) > contract.MAX_BYTES:
            raise ObservationError('git_observation_failed')
        return result.stdout

    def line(self, path, *args, absent=False):
        data = self.run(path, *args, absent=absent)
        if data == b'' and absent:
            return ''
        if not data.endswith(b'\n') or b'\n' in data[:-1]:
            raise ObservationError('ambiguous_git_observation')
        return contract.text(data[:-1].decode('utf-8'), empty=absent)

    def scan(self):
        checkouts, descriptors, seen = set(), set(), set()
        entries = 0
        for root in self.roots:
            start = inside(self.home / contract.relative(root), self.home)
            def failed(_):
                raise ObservationError('workspace_traversal_failed')
            for directory, dirs, files in os.walk(start, followlinks=False, onerror=failed):
                path = Path(directory)
                if path in seen:
                    dirs[:] = []
                    continue
                seen.add(path)
                entries += 1 + len(files)
                if entries > MAX_ENTRIES:
                    raise contract.Unsupported('workspace_scan_limit')
                contract.relative(str(path.relative_to(self.home)))
                if '.git' in dirs or '.git' in files:
                    checkouts.add(path)
                dirs[:] = sorted(name for name in dirs if name != '.git' and not (path / name).is_symlink())
                descriptors.update(path / name for name in files if name.endswith('.code-workspace')
                                   and not (path / name).is_symlink())
        if len(checkouts) + len(descriptors) > contract.MAX_ITEMS:
            raise contract.Unsupported('workspace_inventory_limit')
        return sorted(checkouts), sorted(descriptors)

    def common(self, path):
        marker = inside(path / '.git', self.home)
        if marker.is_file():
            value = read_file(marker).decode('utf-8')
            if not value.startswith('gitdir: ') or not value.endswith('\n') or '\n' in value[:-1]:
                raise contract.Unsupported('gitfile_unsupported')
            target = Path(contract.text(value[8:-1]))
            marker = inside(Path(os.path.abspath(path / target)), self.home)
        common = marker / 'commondir'
        directory = marker
        if common.exists() or common.is_symlink():
            target = Path(contract.text(read_file(common).decode('utf-8').rstrip('\n')))
            directory = inside(Path(os.path.abspath(marker / target)), self.home)
        for git_directory in (marker, directory):
            for name in ('config', 'HEAD', 'objects', 'objects/info/alternates'):
                if (git_directory / name).is_symlink():
                    raise contract.Unsupported('git_metadata_symlink')
        common = self.line(path, 'rev-parse', '--git-common-dir')
        common = inside(Path(os.path.abspath(path / common)), self.home)
        if common != directory:
            raise ObservationError('git_directory_changed')
        unsafe = self.run(path, 'config', '--local', '--no-includes', '--name-only', '--get-regexp',
            r'^(include\.|includeif\.|filter\.|extensions\.(partialclone|worktreeconfig)|remote\..*\.promisor)', absent=True)
        if unsafe or (common / 'objects/info/alternates').exists():
            raise contract.Unsupported('git_external_configuration')
        top = self.line(path, 'rev-parse', '--show-toplevel')
        if top != str(path):
            raise contract.Unsupported('checkout_root_mismatch')
        return common

    def origin(self, path):
        value = self.line(path, 'config', '--local', '--no-includes', '--get', 'remote.origin.url', absent=True)
        if value.startswith(('http://', 'https://')):
            parsed = urlsplit(value)
            if '@' in parsed.netloc:
                value = urlunsplit(parsed._replace(netloc=parsed.netloc.rsplit('@', 1)[1]))
                self.counts['REMOTE_REDACTED'] += 1
        if not value:
            raise contract.Unsupported('repository_origin_unavailable')
        try:
            contract.remote_valid(value)
        except contract.Invalid as exc:
            raise contract.Unsupported('repository_origin_unsupported') from exc
        return value

    def repositories(self, checkouts):
        groups, records, rejected = [], {}, set()
        self.rejected = rejected
        if not checkouts:
            return groups, records
        try:
            self.git = contract.git_executable()
        except contract.Unsupported:
            rejected.update(checkouts)
            self.counts['GIT_CAPABILITY_UNSUPPORTED'] = 1
            self.counts['UNSUPPORTED_REPOSITORIES'] = len(checkouts)
            return groups, records
        observed = {}
        for path in checkouts:
            try:
                common = self.common(path)
            except contract.Unsupported:
                rejected.add(path)
                self.counts['UNSUPPORTED_REPOSITORIES'] += 1
                continue
            observed.setdefault(common, []).append(path)
        if not observed:
            return groups, records
        capability = contract.detect_worktree_capability(cwd=next(iter(observed.values()))[0])
        if capability['status'] != 'supported':
            rejected.update(checkouts)
            self.counts['GIT_CAPABILITY_UNSUPPORTED'] = 1
            self.counts['UNSUPPORTED_REPOSITORIES'] = len(checkouts)
            return groups, records
        for common, candidates in observed.items():
            members = []
            try:
                raw = self.run(candidates[0], 'worktree', 'list', '--porcelain', '-z')
                try:
                    members = porcelain(raw)
                except (contract.Invalid, UnicodeError) as exc:
                    raise contract.Unsupported('worktree_format_unsupported') from exc
                blocked = False
                for member in members:
                    path = Path(member['path'])
                    for flag, counter in (('locked', 'LOCKED_WORKTREES'), ('prunable', 'PRUNABLE_WORKTREES')):
                        if flag in member:
                            self.counts[counter] += 1
                            blocked = True
                    try:
                        relative = str(path.relative_to(self.home))
                        contract.relative(relative)
                        if not any(contract.within(relative, root) for root in self.roots):
                            raise ValueError()
                    except (ValueError, contract.Invalid):
                        self.counts['EXTERNAL_WORKTREES'] += 1
                        blocked = True
                        continue
                    try:
                        path.lstat()
                    except FileNotFoundError:
                        self.counts['MISSING_WORKTREES'] += 1
                        blocked = True
                    else:
                        inside(path, self.home)
                    if 'bare' in member or member.get('HEAD', '').strip('0') == '':
                        blocked = True
                if blocked or {Path(m['path']) for m in members} != set(candidates):
                    raise contract.Unsupported('incomplete_worktree_group')
                base = Path(members[0]['path'])
                # The first porcelain entry is the main checkout, never promote a linked one.
                if base / '.git' != common or not (base / '.git').is_dir():
                    raise contract.Unsupported('base_checkout_unavailable')
                group_records, group_members = {}, []
                for member in members:
                    path = Path(member['path'])
                    if self.common(path) != common:
                        raise ObservationError('worktree_relationship_changed')
                    oid = self.line(path, 'rev-parse', '--verify', 'HEAD')
                    branch = self.line(path, 'symbolic-ref', '--quiet', 'HEAD', absent=True)
                    if oid != member['HEAD'] or branch != member.get('branch', ''):
                        raise ObservationError('worktree_head_changed')
                    relative = str(path.relative_to(self.home))
                    item = contract.identity('checkout', relative)
                    status = self.run(path, 'status', '--porcelain=v1', '-z', '--untracked-files=no')
                    values = dict(NAME=path.name, PATH='~/' + relative, REMOTE=self.origin(path),
                        CURRENT_BRANCH=branch[11:] if branch else '', DEFAULT_BRANCH='',
                        HAS_UNCOMMITTED_CHANGES=str(bool(status)).lower(), TOPOLOGY_VERSION='1')
                    for key, leaf in (('HAS_VSCODE_FOLDER', ''), ('HAS_SETTINGS', 'settings.json'),
                                      ('HAS_TASKS', 'tasks.json'), ('HAS_LAUNCH', 'launch.json'),
                                      ('HAS_EXTENSIONS', 'extensions.json')):
                        target = path / '.vscode' / leaf
                        values[key] = str(not (path / '.vscode').is_symlink() and
                                          not target.is_symlink() and target.exists()).lower()
                    group_records[item] = values
                    group_members.append(dict(item_id=item, head_kind='branch' if branch else 'detached', head_oid=oid))
                if self.run(candidates[0], 'worktree', 'list', '--porcelain', '-z') != raw:
                    raise ObservationError('worktree_inventory_changed')
                groups.append(dict(id=contract.identity('repository', str(base.relative_to(self.home))),
                    base_item_id=contract.identity('checkout', str(base.relative_to(self.home))),
                    object_format='sha1' if len(members[0]['HEAD']) == 40 else 'sha256', members=group_members))
                records.update(group_records)
            except contract.Unsupported:
                rejected.update(candidates)
                self.counts['UNSUPPORTED_REPOSITORIES'] += len(candidates)
        # Never keep a nested checkout while excluding its enclosing repository.
        while True:
            bad = [g for g in groups if any(any((self.home / records[m['item_id']]['PATH'][2:]).is_relative_to(p)
                      for p in rejected) for m in g['members'])]
            if not bad:
                break
            for group in bad:
                groups.remove(group)
                for member in group['members']:
                    rejected.add(self.home / records.pop(member['item_id'])['PATH'][2:])
                    self.counts['UNSUPPORTED_REPOSITORIES'] += 1
        return groups, records

    def workspaces(self, paths, records):
        items, flat = [], []
        for path in paths:
            try:
                value = jsonc(read_file(path))
                if not isinstance(value, dict) or not isinstance(value.get('folders'), list) or not value['folders']:
                    raise contract.Unsupported('workspace_folders_unavailable')
                folders = []
                for folder in value['folders']:
                    if not isinstance(folder, dict) or set(folder) - {'path', 'name'} or 'path' not in folder:
                        raise contract.Unsupported('workspace_folder_unsupported')
                    target = Path(os.path.abspath(path.parent / contract.text(folder['path'])))
                    try:
                        inside(target, self.home)
                    except FileNotFoundError as missing:
                        # Only a stable missing folder excludes this descriptor. An
                        # unreadable path or a descriptor disappearing after scan is an error.
                        try:
                            inside(target, self.home)
                        except FileNotFoundError as confirmed:
                            if missing.filename != confirmed.filename:
                                raise ObservationError('workspace_folder_changed') from confirmed
                            raise contract.Unsupported('workspace_folder_missing') from confirmed
                        raise ObservationError('workspace_folder_changed') from missing
                    if not stat.S_ISDIR(target.lstat().st_mode):
                        raise contract.Unsupported('workspace_folder_type_unsupported')
                    if any(target.is_relative_to(p) for p in self.rejected):
                        raise contract.Unsupported('workspace_repository_unavailable')
                    relative = str(target.relative_to(self.home))
                    contract.relative(relative)
                    matches = [(len(row['PATH']), 'git-repositories', item, row['PATH'][2:])
                               for item, row in records.items() if contract.within(relative, row['PATH'][2:])]
                    if not matches:
                        matches = [(len(root), 'workspace-folders', root, root) for root in self.roots
                                   if contract.within(relative, root)]
                    if not matches:
                        raise contract.Unsupported('external_workspace_folder')
                    _, domain, item, parent = max(matches)
                    row = dict(domain=domain, item_id=item, subpath=relative[len(parent):].lstrip('/'))
                    if 'name' in folder:
                        row['name'] = contract.text(folder['name'], 160)
                    folders.append(row)
                relative = str(path.relative_to(self.home))
                item = contract.identity('workspace', relative)
                items.append(dict(item_id=item, path='~/' + relative, folders=folders))
                flat.append(f'[{item}]\nPATH="~/{relative}"\n\n')
            except ObservationError:
                raise
            except (contract.Invalid, ValueError):
                self.counts['UNSUPPORTED_WORKSPACES'] += 1
        return items, ''.join(flat).encode()


def jsonc(data):
    """Bounded JSONC lexer: strip comments/trailing commas outside JSON strings."""
    source = data.decode('utf-8-sig')
    pattern = re.compile(r'"(?:[^"\\]|\\.)*"|//[^\r\n]*|/\*[\s\S]*?\*/', re.M)
    source = pattern.sub(lambda m: m[0] if m[0].startswith('"') else ' ', source)
    pattern = re.compile(r'"(?:[^"\\]|\\.)*"|,\s*(?=[}\]])')
    source = pattern.sub(lambda m: m[0] if m[0].startswith('"') else '', source)
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate_workspace_key')
            result[key] = value
        return result
    return json.loads(source, object_pairs_hook=unique)


def collect(home, staging):
    folders = (staging / 'folders.conf').read_bytes()
    roots = [line.split('|')[0] for line in folders.decode().splitlines() if line.endswith('|workspace')]
    extra = os.environ.get('MACSEED_WORKSPACE_ROOTS', '').splitlines()
    for root in extra:
        contract.relative(root)
        if root not in roots:
            roots.append(root)
            folders += (root + '|workspace\n').encode()
    observer = Observer(home, roots)
    checkouts, descriptors = observer.scan()
    groups, records = observer.repositories(checkouts)
    workspaces, flat = observer.workspaces(descriptors, records)
    files = {'generated/workspace/folders.conf': folders, contract.REPOSITORIES: b'',
             'generated/workspace/vscode-workspaces.conf': flat}
    for item, row in sorted(records.items()):
        for value in row.values():
            contract.text(value, empty=True)
            if '"' in value:
                raise contract.Unsupported('sectional_value_unsupported')
        files[contract.REPOSITORIES] += ('[' + item + ']\n' + ''.join(
            f'{key}="{value}"\n' for key, value in row.items()) + '\n').encode()
    if groups:
        files[contract.TOPOLOGY] = (json.dumps(dict(contract=1, roots=sorted(roots),
            groups=sorted(groups, key=lambda g: g['id'])), sort_keys=True) + '\n').encode()
    if workspaces:
        files[contract.VSCODE] = (json.dumps(dict(contract=1, items=workspaces), sort_keys=True) + '\n').encode()
    # Full relationships first; descriptors remain unselected until a future UX.
    contract.validate(files, {'git-repositories': list(records)}, exact=False)
    for name, data in files.items():
        if len(data) > contract.MAX_BYTES:
            raise contract.Invalid('workspace_metadata_oversized')
        target = staging / Path(name).name
        target.write_bytes(data)
        target.chmod(0o600)
    (staging / 'inventory.extra').write_text(''.join(f'{key}={value}\n' for key, value in observer.counts.items()))
    return observer.counts


def validate_stage(staging):
    files = {}
    for name in (contract.TOPOLOGY, contract.VSCODE, contract.REPOSITORIES, 'generated/workspace/folders.conf'):
        path = staging / Path(name).name
        if path.exists() or path.is_symlink():
            files[name] = read_file(path)
    if not any(name in files for name in contract.FEATURES) and b'TOPOLOGY_VERSION=' not in files.get(contract.REPOSITORIES, b''):
        return
    records = contract.repository_records(files[contract.REPOSITORIES]) if contract.TOPOLOGY in files else {}
    contract.validate(files, {'git-repositories': list(records)}, home=os.environ['HOME'])


if __name__ == '__main__':
    try:
        if sys.argv[1] == '--validate':
            validate_stage(Path(sys.argv[2]))
        else:
            collect(os.environ['HOME'], Path(sys.argv[1]))
    except (OSError, ValueError, UnicodeError, RecursionError, subprocess.SubprocessError):
        print('Workspace topology observation failed; previous snapshot preserved', file=sys.stderr)
        sys.exit(2)
