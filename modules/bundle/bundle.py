#!/usr/bin/env python3
"""Fixed Bootstrap Bundle v1 format and local publication. No code is loaded from a bundle."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "config"
RECOVERY = CONFIG / ".bundle-publication"
ITEMS = {
    "homebrew-packages": "brew-packages.conf",
    "homebrew-casks": "brew-casks.conf",
    "app-store": "appstore.conf",
    "vscode-extensions": "vscode-extensions.conf",
    "workspace-folders": "workspace/folders.conf",
    "git-repositories": "workspace/repositories.conf",
    "git-configuration": "git.conf",
}
# Schema-only domains are intentionally absent from runtime/UI inventories.
EXTENSION_ITEMS = {"vscode-workspaces": "workspace/vscode-workspaces.json"}
WORKSPACE_EXTENSIONS = {
    "generated/workspace/topology.json": "workspace-topology",
    "generated/workspace/vscode-workspaces.json": "vscode-workspaces",
}
_workspace_contract = None
CATEGORIES = {
    "ssh-configuration": "ssh/config.snapshot",
    "vscode-settings": "vscode/settings.json",
    "shell-zsh": "shell/zshrc.snapshot",
    "macos-finder": "macos/finder.conf",
    "macos-dock": "macos/dock.conf",
    "macos-windows": "macos/windows.conf",
    "macos-keyboard": "macos/keyboard.conf",
    "macos-trackpad": "macos/trackpad.conf",
    "macos-screenshots": "macos/screenshots.conf",
}
CATEGORY_FLAGS = set(CATEGORIES) | {"git-configuration"}
GROUPS = {
    "Applications": ("homebrew-casks", "app-store", "vscode-extensions"),
    "VS Code Settings": ("vscode-settings",),
    "Homebrew": ("homebrew-packages",),
    "macOS Settings": tuple(k for k in CATEGORIES if k.startswith("macos-")),
    "Shell": ("shell-zsh",),
    "Git": ("git-configuration",),
    "SSH Configuration": ("ssh-configuration",),
    "Workspace": ("workspace-folders", "git-repositories"),
}
MAX_ARCHIVE = 48 * 1024 * 1024
MAX_MEMBER = 33 * 1024 * 1024
MAX_ENTRIES = 32
COMPLETE_INVENTORIES = {
    "homebrew-casks": "brew-casks.conf",
    "app-store": "appstore.conf",
    "vscode-extensions": "vscode-extensions.conf",
}


class Invalid(Exception):
    pass


class Unsupported(Invalid):
    pass


class WorkspaceSelectionInvalid(Invalid):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def workspace_contract():
    global _workspace_contract
    if _workspace_contract is None:
        spec = importlib.util.spec_from_file_location(
            'workspace_topology', ROOT / 'modules/bootstrap/workspace/topology.py')
        _workspace_contract = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_workspace_contract)
    return _workspace_contract


def workspace_extension_present(files):
    return (any(name in files for name in WORKSPACE_EXTENSIONS) or
            re.search(rb'^TOPOLOGY_VERSION=', files.get('generated/workspace/repositories.conf', b''), re.M) is not None)


def validate_workspace(files, *, home=None, exact=False, inspect_home=False):
    sections, _ = parse_blueprint(files['blueprint.conf'])
    if not workspace_extension_present(files) and not sections.get('vscode-workspaces'):
        return {}
    contract = workspace_contract()
    try:
        return contract.validate(files, sections, home=home, exact=exact, inspect_home=inspect_home)
    except contract.SelectionInvalid as exc:
        raise WorkspaceSelectionInvalid(exc.code) from exc
    except contract.Unsupported as exc:
        raise Unsupported(str(exc)) from exc
    except (contract.Invalid, OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as exc:
        raise Invalid('invalid Workspace topology: ' + str(exc) if isinstance(exc, contract.Invalid)
                      else 'Workspace topology validation failed') from exc


def require_runtime_workspace(files):
    # No narrowing, fallback, publication or UI interpretation of Phase 1 data.
    blueprint = files.get('blueprint.conf', b'')
    selected = (parse_blueprint(blueprint)[0].get('vscode-workspaces', [])
                if b'[vscode-workspaces]' in blueprint else [])
    if workspace_extension_present(files) or selected:
        raise Unsupported('Workspace topology runtime is not enabled')


def workspace_stage_files(stage):
    names = (*WORKSPACE_EXTENSIONS, 'generated/workspace/repositories.conf', 'blueprint.conf')
    return {name: checked_file(stage / name) for name in names
            if (stage / name).exists() or (stage / name).is_symlink()}


def staged_payload(stage, blueprint):
    files = {path: checked_file(stage / path) for path in required_paths(blueprint) if path != 'blueprint.conf'}
    files['blueprint.conf'] = blueprint
    topology = 'generated/workspace/topology.json'
    if (stage / topology).exists() or (stage / topology).is_symlink():
        files[topology] = checked_file(stage / topology)
        # Validate the complete inventory; selected checkouts retain explicit
        # base/parent dependencies even when those parents are unselected.
        name = 'generated/workspace/repositories.conf'
        files[name] = checked_file(stage / name)
    return files


def checked_file(path, limit=MAX_MEMBER):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > limit:
        raise Invalid("unsafe or oversized input file")
    return path.read_bytes()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def parse_blueprint(data):
    try:
        lines = data.decode("utf-8").splitlines()
    except UnicodeDecodeError as exc:
        raise Invalid("Blueprint is not UTF-8") from exc
    sections = {}
    current = None
    for line in lines:
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1]
            if current in sections or current not in ("categories", *ITEMS, *EXTENSION_ITEMS):
                raise Invalid("invalid Blueprint section")
            sections[current] = []
        elif current is None:
            raise Invalid("Blueprint data outside section")
        else:
            sections[current].append(line)
    if set(sections) - set(EXTENSION_ITEMS) != {"categories", *ITEMS}:
        raise Invalid("incomplete Blueprint")
    categories = {}
    for line in sections["categories"]:
        match = re.fullmatch(r'([a-z-]+)="(true|false)"', line)
        if not match or match[1] not in CATEGORY_FLAGS or match[1] in categories:
            raise Invalid("invalid Blueprint category")
        categories[match[1]] = match[2] == "true"
    if set(categories) != CATEGORY_FLAGS:
        raise Invalid("incomplete Bundle Blueprint categories")
    if not categories["git-configuration"] and sections["git-configuration"]:
        raise Invalid("disabled Git category contains selected items")
    return sections, categories


def required_paths(blueprint):
    sections, categories = parse_blueprint(blueprint)
    result = {"blueprint.conf"}
    for section, relative in ITEMS.items():
        if sections[section]:
            result.add("generated/" + relative)
    for section, relative in EXTENSION_ITEMS.items():
        if sections.get(section):
            result.add("generated/" + relative)
    for category, relative in CATEGORIES.items():
        if categories.get(category, False):
            result.add("generated/" + relative)
    return result


def without_empty_workspace_selection(blueprint):
    """An empty optional selection carries no capability; keep legacy syntax."""
    sections, _ = parse_blueprint(blueprint)
    if 'vscode-workspaces' not in sections or sections['vscode-workspaces']:
        return blueprint
    current = None
    output = []
    for line in blueprint.decode('utf-8').splitlines(keepends=True):
        if line.startswith('[') and line.rstrip('\r\n').endswith(']'):
            current = line.rstrip('\r\n')[1:-1]
        if current != 'vscode-workspaces':
            output.append(line)
    return ''.join(output).encode('utf-8')


def completeness_files(stage):
    """Optional, digest-bound full inventories; absent markers mean legacy unknown."""
    result = {}
    for domain, inventory in COMPLETE_INVENTORIES.items():
        marker = stage / "generated/provenance" / (domain + ".sha256")
        if not marker.exists() and not marker.is_symlink():
            continue
        content = checked_file(marker, 128)
        name = "generated/" + inventory
        data = checked_file(stage / name)
        if content != ("complete " + digest(data) + "\n").encode():
            raise Invalid("invalid inventory completeness marker")
        result[name] = data
        result["generated/provenance/" + domain + ".sha256"] = content
    return result


def safe_relative_home(value, home):
    home = home.rstrip("/")
    if not value.startswith(home + "/"):
        raise Invalid("selected path is outside source HOME")
    suffix = value[len(home) + 1:]
    if not suffix or any(part in ("", ".", "..") for part in suffix.split("/")):
        raise Invalid("unsafe HOME-relative path")
    return "~/" + suffix


def portable_paths(files, home):
    repo = "generated/workspace/repositories.conf"
    if repo in files:
        try:
            content = files[repo].decode("utf-8")
        except UnicodeDecodeError as exc:
            raise Invalid("invalid repository encoding") from exc
        lines = []
        for line in content.splitlines(keepends=True):
            if line.startswith('PATH="') and line.endswith('"\n'):
                value = line[6:-2]
                if 'generated/workspace/topology.json' in files:
                    value = '~/' + workspace_contract().portable(value, home)
                else:
                    value = safe_relative_home(value, home)
                line = 'PATH="' + value + '"\n'
            lines.append(line)
        files[repo] = "".join(lines).encode()
    screenshot = "generated/macos/screenshots.conf"
    if screenshot in files:
        try:
            content = files[screenshot].decode("utf-8")
        except UnicodeDecodeError as exc:
            raise Invalid("invalid screenshot encoding") from exc
        lines = []
        for line in content.splitlines(keepends=True):
            if line.startswith("com.apple.screencapture|location|string|"):
                value = line.rstrip("\n").split("|", 3)[3]
                if value.startswith("/"):
                    value = safe_relative_home(value, home)
                elif not value.startswith("~/"):
                    raise Invalid("unsupported screenshot destination")
                line = "com.apple.screencapture|location|string|" + value + "\n"
            lines.append(line)
        files[screenshot] = "".join(lines).encode()


def selected_payload(files, blueprint, *, home=None):
    sections, _ = parse_blueprint(blueprint)
    topology = 'generated/workspace/topology.json' in files
    if workspace_extension_present(files):
        validate_workspace(dict(files, **{'blueprint.conf': blueprint}), home=home)
        workspace_contract().selected_payload(files, sections)
    for section in ("homebrew-packages", "homebrew-casks", "app-store",
                    "vscode-extensions", "workspace-folders"):
        if "generated/provenance/" + section + ".sha256" in files:
            continue  # Keep the complete captured inventory as exclusion baseline.
        name = "generated/" + ITEMS[section]
        if name not in files:
            continue
        selected = set(sections[section])
        lines = files[name].decode("utf-8").splitlines()
        files[name] = ("".join(line + "\n" for line in lines
                               if (line.split("|", 1)[0] if section in
                                   ("app-store", "workspace-folders") else line) in selected)).encode()
    name = "generated/workspace/repositories.conf"
    if name in files and not topology:
        selected = set(sections["git-repositories"])
        current = None
        output = []
        for line in files[name].decode("utf-8").splitlines(keepends=True):
            if line.startswith("[") and line.rstrip().endswith("]"):
                current = line.strip()[1:-1]
            if current in selected:
                output.append(line)
        files[name] = "".join(output).encode()
    name = "generated/git.conf"
    if name in files:
        with tempfile.TemporaryDirectory(prefix="mbt-git-") as directory:
            source = Path(directory) / "source"
            target = Path(directory) / "selected"
            write_file(source, files[name])
            result = subprocess.run(["git", "config", "--file", str(source),
                                     "--no-includes", "--null", "--list"],
                                    capture_output=True, check=False, timeout=30)
            if result.returncode:
                raise Invalid("invalid selected Git configuration")
            selected = {key.lower() for key in sections["git-configuration"]}
            for record in result.stdout.split(b"\0"):
                if not record:
                    continue
                key, separator, value = record.partition(b"\n")
                if not separator:
                    raise Invalid("invalid Git configuration record")
                if key.decode("ascii").lower() not in selected:
                    continue
                written = subprocess.run(["git", "config", "--file", str(target),
                                          key.decode("ascii"), value.decode("utf-8")],
                                         capture_output=True, check=False, timeout=30)
                if written.returncode:
                    raise Invalid("failed to select Git configuration")
            files[name] = target.read_bytes() if target.exists() else b""


def target_paths(files, home):
    home = home.rstrip("/")
    repo = "generated/workspace/repositories.conf"
    if repo in files:
        lines = []
        for line in files[repo].decode().splitlines(keepends=True):
            if line.startswith('PATH="'):
                if not line.endswith('"\n') or not line[6:-2].startswith("~/"):
                    raise Invalid("nonportable repository path")
                value = line[8:-2]
                if not value or any(part in ("", ".", "..") for part in value.split("/")):
                    raise Invalid("unsafe repository path")
                line = 'PATH="' + home + "/" + value + '"\n'
            lines.append(line)
        files[repo] = "".join(lines).encode()
    screenshot = "generated/macos/screenshots.conf"
    if screenshot in files:
        for line in files[screenshot].decode().splitlines():
            if line.startswith("com.apple.screencapture|location|string|"):
                value = line.split("|", 3)[3]
                if not value.startswith("~/"):
                    raise Invalid("nonportable screenshot path")
                suffix = value[2:]
                if not suffix or any(part in ("", ".", "..") for part in suffix.split("/")):
                    raise Invalid("unsafe screenshot path")


def write_file(path, data):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with path.open("xb") as out:
        os.fchmod(out.fileno(), 0o600)
        out.write(data)


def check_replacement(path, expected):
    # No-follow observation; user consent cannot authorize a changed destination.
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_size > MAX_ARCHIVE:
            raise Invalid("unsafe replacement destination")
        value = hashlib.sha256()
        observed_size = 0
        for chunk in iter(lambda: stream.read(65536), b""):
            observed_size += len(chunk)
            if observed_size > MAX_ARCHIVE:
                raise Invalid("oversized replacement destination")
            value.update(chunk)
        after = os.fstat(stream.fileno())
        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns) or value.hexdigest() != expected:
            raise Invalid("replacement destination changed")
        current = path.lstat()
        if (current.st_dev, current.st_ino) != (before.st_dev, before.st_ino):
            raise Invalid("replacement destination changed")


def external_tools_provenance(value):
    if (not isinstance(value, dict) or set(value) - {'homebrew'} or
            any(not isinstance(row, dict) or set(row) != {'version'} or
                not isinstance(row['version'], str) or not 0 < len(row['version']) <= 256 or
                any(ord(c) < 32 or ord(c) == 127 for c in row['version'])
                for row in value.values())):
        raise Invalid('invalid external-tool provenance')
    return value


def cask_capabilities(value):
    if (not isinstance(value, dict) or set(value) != {'contract', 'casks'} or value['contract'] != 1 or
            not isinstance(value['casks'], dict) or len(value['casks']) > 2048):
        raise Invalid('invalid cask capability evidence')
    for token, row in value['casks'].items():
        if (not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9+_.@-]*', token) or not isinstance(row, dict) or
                set(row) != {'state', 'reason', 'required'} or row['state'] not in {
                    'satisfied', 'installable', 'repairable', 'unsupported', 'incompatible', 'observation_error'} or
                row['reason'] is not None and not re.fullmatch(r'[a-z][a-z0-9_]{0,63}', str(row['reason'])) or
                not isinstance(row['required'], list) or len(row['required']) > 50000):
            raise Invalid('invalid cask capability evidence')
        for predicate in row['required']:
            if (not isinstance(predicate, dict) or not {'kind', 'identity'} <= set(predicate) or
                    set(predicate) - {'kind', 'identity', 'target', 'bundle_id', 'members'} or
                    predicate['kind'] not in {'app', 'suite', 'bundle', 'file', 'link', 'wrapper', 'receipt'} or
                    not isinstance(predicate['identity'], str) or not 0 < len(predicate['identity']) <= 255 or
                    any(ord(c) < 32 or ord(c) == 127 or c == '/' for c in predicate['identity'])):
                raise Invalid('invalid cask payload predicate')
            if 'bundle_id' in predicate and (predicate['kind'] != 'app' or not isinstance(predicate['bundle_id'], str) or
                    not re.fullmatch(r'[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+', predicate['bundle_id'])):
                raise Invalid('invalid captured application identity')
            if 'members' in predicate:
                members = predicate['members']
                if (predicate['kind'] != 'suite' or not isinstance(members, list) or not 0 < len(members) <= 2048 or
                        any(not isinstance(member, dict) or set(member) != {'name', 'bundle_id'} or
                            not isinstance(member['name'], str) or '/' in member['name'] or
                            not member['name'].endswith('.app') or any(ord(c) < 32 for c in member['name']) or
                            not isinstance(member['bundle_id'], str) or
                            not re.fullmatch(r'[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+', member['bundle_id']) for member in members)):
                    raise Invalid('invalid captured suite members')
            if 'target' in predicate:
                target = predicate['target']
                if (not isinstance(target, dict) or set(target) != {'root', 'relative'} or
                        target['root'] not in {'applications', 'home', 'prefix', 'library', 'system'} or
                        not isinstance(target['relative'], str) or len(target['relative']) > 4096 or
                        any(part in ('', '.', '..') for part in target['relative'].split('/')) or
                        any(ord(c) < 32 or ord(c) == 127 for c in target['relative'])):
                    raise Invalid('invalid portable cask target')
        if row['state'] in ('satisfied', 'repairable', 'installable') and not row['required']:
            raise Invalid('empty cask payload predicates')
    return value


def application_precedence(blueprint, capabilities, allow_installed=False):
    """Narrow effective requirements; source inventories and distributions stay intact."""
    sys.path.insert(0, str(ROOT / 'modules/apps'))
    from application_identity import overlaps
    sections, _ = parse_blueprint(blueprint)
    pairs, observed = overlaps(sections['homebrew-casks'], sections['app-store'],
                               capabilities, allow_installed)
    current = None
    lines = []
    for line in blueprint.decode().splitlines(keepends=True):
        if line.startswith('[') and line.rstrip().endswith(']'):
            current = line.strip()[1:-1]
        if current == 'app-store' and line.strip() in pairs:
            continue
        lines.append(line)
    return ''.join(lines).encode(), pairs, observed


def deduplicate_applications(stage):
    """Apply precedence to private Restore state after explicit user selection."""
    path = stage / 'generated/homebrew-casks.json'
    capabilities = cask_capabilities(json.loads(checked_file(path))) if path.exists() or path.is_symlink() else {'contract': 1, 'casks': {}}
    blueprint, pairs, observed = application_precedence(
        checked_file(stage / 'blueprint.conf', 65536), capabilities, allow_installed=True)
    if pairs:
        # Bind observed legacy identities to the same independent Cask predicates
        # used by Preview, Execute requalification and final Verification.
        if observed:
            capabilities['casks'].update(observed)
            temporary = path.with_name('homebrew-casks.precedence')
            write_file(temporary, (json.dumps(cask_capabilities(capabilities), sort_keys=True) + '\n').encode())
            temporary.replace(path)
        temporary = stage / 'blueprint.precedence'
        write_file(temporary, blueprint)
        temporary.replace(stage / 'blueprint.conf')
    return pairs


def pack(stage, output, home, replacement_sha256=None, *, apply_precedence=True):
    blueprint = without_empty_workspace_selection(checked_file(stage / "blueprint.conf", 65536))
    capabilities = stage / 'generated/homebrew-casks.json'
    data = cask_capabilities(json.loads(checked_file(capabilities))) if capabilities.exists() or capabilities.is_symlink() else {'contract': 1, 'casks': {}}
    # Discovery remains domain-local. Resolve overlaps only after its complete
    # staged observations and the Capture selection exist, before atomic packing.
    if apply_precedence:
        blueprint, _, _ = application_precedence(blueprint, data)
    files = staged_payload(stage, blueprint)
    files.update(completeness_files(stage))
    if capabilities.exists() or capabilities.is_symlink():
        selected, _ = parse_blueprint(blueprint)
        data['casks'] = {token: row for token, row in data['casks'].items() if token in selected['homebrew-casks']}
        if data['casks']:
            files['generated/homebrew-casks.json'] = (json.dumps(data, sort_keys=True) + '\n').encode()
    selected_payload(files, blueprint, home=home)
    zsh = files.get("generated/shell/zshrc.snapshot")
    if zsh is not None and not zsh.startswith(b"MBT-ZSHRC-1\nstatus=eligible\n"):
        raise Invalid("selected Zsh snapshot is not eligible")
    portable_paths(files, home)
    features = validate_workspace(files, exact=True)
    secure = stage / "secure.age"
    if secure.exists() or secure.is_symlink():
        files["secure.age"] = checked_file(secure, 33 * 1024 * 1024)
    manifest = {
        "format": "mac-bootstrap-bundle",
        "version": 1,
        "files": {name: {"size": len(data), "sha256": digest(data)}
                  for name, data in sorted(files.items())},
    }
    if features:
        manifest['required_features'] = features
    provenance = stage / 'generated/provenance/homebrew.json'
    if provenance.exists() or provenance.is_symlink():
        try:
            manifest['external_tools'] = external_tools_provenance(json.loads(checked_file(provenance, 4096)))
        except (ValueError, UnicodeError) as exc:
            raise Invalid('invalid external-tool provenance') from exc
    files["manifest.json"] = (json.dumps(manifest, sort_keys=True) + "\n").encode()
    if replacement_sha256 is None:
        if output.exists() or output.is_symlink():
            raise Invalid("Bundle destination exists")
    else:
        check_replacement(output, replacement_sha256)
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.parent.is_symlink():
        raise Invalid("unsafe Bundle destination parent")
    fd, temporary = tempfile.mkstemp(prefix=".bundle-", dir=output.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as stream:
            with tarfile.open(fileobj=stream, mode="w", format=tarfile.USTAR_FORMAT) as tar:
                for name, data in sorted(files.items()):
                    header = tarfile.TarInfo(name)
                    header.size = len(data)
                    header.mode = 0o600
                    import io
                    tar.addfile(header, io.BytesIO(data))
            stream.flush()
            os.fsync(stream.fileno())
        if os.path.getsize(temporary) > MAX_ARCHIVE:
            raise Invalid("Bundle is too large")
        validate_archive(Path(temporary))
        if replacement_sha256 is not None:
            # The old file stays intact through creation/fsync/archive validation.
            check_replacement(output, replacement_sha256)
            os.replace(temporary, output)
        else:
            try:
                os.link(temporary, output)
            except FileExistsError as exc:
                raise Invalid("Bundle destination appeared") from exc
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def validate_archive(path, with_provenance=False):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_ARCHIVE:
        raise Invalid("unsafe or oversized Bundle")
    raw = path.read_bytes()
    offset = 0
    raw_members = []
    while offset + 512 <= len(raw):
        header = raw[offset:offset + 512]
        if header == bytes(512):
            if any(raw[offset:]):
                raise Invalid("unexpected archive trailer")
            break
        if header[156:157] not in (b"0", b"\0") or header[345:500].strip(b"\0"):
            raise Invalid("unsupported archive entry")
        try:
            name = header[:100].split(b"\0", 1)[0].decode("ascii")
            size_field = header[124:136].strip(b"\0 ")
            if not size_field or any(byte not in b"01234567" for byte in size_field):
                raise ValueError()
            size = int(size_field, 8)
        except (UnicodeError, ValueError) as exc:
            raise Invalid("invalid archive header") from exc
        if size > MAX_MEMBER:
            raise Invalid("oversized archive entry")
        if len(raw_members) >= MAX_ENTRIES:
            raise Invalid("too many Bundle entries")
        next_offset = offset + 512 + ((size + 511) // 512) * 512
        if next_offset <= offset or next_offset > len(raw):
            raise Invalid("invalid archive entry size")
        raw_members.append((name, size))
        offset = next_offset
    else:
        raise Invalid("truncated archive")
    files = {}
    with tarfile.open(path, mode="r:") as tar:
        members = tar.getmembers()
        if len(members) > MAX_ENTRIES or raw_members != [(m.name, m.size) for m in members]:
            raise Invalid("too many Bundle entries")
        for member in members:
            name = member.name
            if (member.type not in (tarfile.REGTYPE, tarfile.AREGTYPE) or
                member.pax_headers or member.size > MAX_MEMBER or
                name in files or name.startswith("/") or
                any(part in ("", ".", "..") for part in name.split("/")) or
                name not in {"manifest.json", "blueprint.conf", "secure.age", "generated/homebrew-casks.json", *WORKSPACE_EXTENSIONS,
                             *("generated/" + item for item in (*ITEMS.values(), *CATEGORIES.values())),
                             *("generated/provenance/" + item + ".sha256"
                               for item in COMPLETE_INVENTORIES)}):
                raise Invalid("unexpected Bundle entry")
            files[name] = tar.extractfile(member).read()
    if "manifest.json" not in files or "blueprint.conf" not in files:
        raise Invalid("incomplete Bundle")
    try:
        manifest = json.loads(files.pop("manifest.json"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise Invalid("invalid Bundle manifest") from exc
    if not isinstance(manifest, dict) or manifest.get("format") != "mac-bootstrap-bundle" or manifest.get("version") != 1:
        raise Unsupported("unsupported Bundle version")
    provenance = external_tools_provenance(manifest.get('external_tools', {}))
    expected = required_paths(files["blueprint.conf"])
    if 'generated/workspace/topology.json' in files:
        expected.add('generated/workspace/topology.json')
    required_features = manifest.get('required_features', {})
    if (not isinstance(required_features, dict) or
            any(key not in WORKSPACE_EXTENSIONS.values() or type(value) is not int or value != 1
                for key, value in required_features.items())):
        raise Unsupported('unsupported Bundle capabilities')
    if 'generated/homebrew-casks.json' in files:
        capabilities = cask_capabilities(json.loads(files['generated/homebrew-casks.json']))
        selected, _ = parse_blueprint(files['blueprint.conf'])
        if not capabilities['casks'] or set(capabilities['casks']) - set(selected['homebrew-casks']):
            raise Invalid('cask capability evidence does not match selection')
        expected.add('generated/homebrew-casks.json')
    for domain, inventory in COMPLETE_INVENTORIES.items():
        marker = "generated/provenance/" + domain + ".sha256"
        if marker in files:
            name = "generated/" + inventory
            if name not in files or files[marker] != ("complete " + digest(files[name]) + "\n").encode():
                raise Invalid("invalid inventory completeness marker")
            expected.add(marker)
            expected.add(name)
    if "secure.age" in files:
        if not files["secure.age"].startswith(b"age-encryption.org/v1\n"):
            raise Invalid("invalid encrypted SSH package header")
        expected.add("secure.age")
    if (not isinstance(manifest.get("files"), dict) or set(files) != expected or
        set(manifest["files"]) != expected):
        raise Invalid("Bundle content does not match selection")
    for name, data in files.items():
        record = manifest["files"][name]
        if record != {"size": len(data), "sha256": digest(data)}:
            raise Invalid("Bundle integrity mismatch")
    if required_features != validate_workspace(files, exact=True):
        raise Invalid('Bundle Workspace capabilities do not match payload')
    return (files, provenance) if with_provenance else files


def unpack(bundle, stage, home, *, workspace_preview=False):
    files, provenance = validate_archive(bundle, with_provenance=True)
    if workspace_preview:
        require_workspace_preview(files)
    else:
        require_runtime_workspace(files)
    target_paths(files, home)
    files['blueprint.conf'] = without_empty_workspace_selection(files['blueprint.conf'])
    (stage / "generated").mkdir(mode=0o700, exist_ok=True)
    for name, data in files.items():
        write_file(stage / name, data)
    if provenance:
        write_file(stage / 'generated/provenance/homebrew.json',
                   (json.dumps(provenance, sort_keys=True) + '\n').encode())


def inspect_bundle(bundle, home):
    """Validate as Restore does, then return only UI-safe selection metadata."""
    files, provenance = validate_archive(bundle, with_provenance=True)
    target_paths(files, home)
    sections, categories = parse_blueprint(files["blueprint.conf"])
    return {
        "format_version": 1,
        "selected_categories": sorted(name for name, enabled in categories.items() if enabled),
        "selected_item_counts": {name: len(sections[name]) for name in ITEMS},
        "secure_component": "secure.age" in files,
        "external_tools": provenance,
    }


def require_workspace_preview(files):
    # Phase 3 admits topology reads only. Descriptor restoration is still absent.
    if 'generated/workspace/vscode-workspaces.json' in files:
        raise Unsupported('VS Code workspace restoration is not enabled')


def capture_preview(stage, home, *, topology_folders=False):
    """Validate selected metadata, then project domains for legacy Preview.

    This private Preview-only Blueprint is never the saved Bundle selection.
    Capture retains folder checks; Restore's topology inspector handles both roles.
    """
    blueprint = checked_file(stage / 'blueprint.conf', 65536)
    files = staged_payload(stage, blueprint)
    selected_payload(files, blueprint, home=home)
    portable_paths(files, home)
    validate_workspace(files, exact=True)
    excluded = {'vscode-workspaces'}
    if 'generated/workspace/topology.json' in files:
        excluded.add('git-repositories')
        if topology_folders:
            excluded.add('workspace-folders')
    current, output = None, []
    for line in blueprint.decode().splitlines(keepends=True):
        if line.startswith('[') and line.rstrip().endswith(']'):
            current = line.strip()[1:-1]
            if current != 'vscode-workspaces':
                output.append(line)
        elif current not in excluded:
            output.append(line)
    return ''.join(output).encode()


def narrow(stage, groups, *, workspace_preview=False):
    files = workspace_stage_files(stage)
    if workspace_preview:
        require_workspace_preview(files)
    else:
        require_runtime_workspace(files)
    path = stage / "blueprint.conf"
    original = checked_file(path, 65536).decode()
    disabled = {item for group in groups for item in GROUPS[group]}
    current = None
    output = []
    for line in original.splitlines(keepends=True):
        if line.startswith("[") and line.rstrip().endswith("]"):
            current = line.strip()[1:-1]
        if current == "categories":
            key = line.split("=", 1)[0]
            if key in disabled:
                line = key + '="false"\n'
        elif current in disabled and current in ITEMS and not line.startswith("["):
            if line.strip() and not line.startswith("#"):
                continue
        output.append(line)
    replacement = path.with_name("blueprint.narrow")
    write_file(replacement, "".join(output).encode())
    os.replace(replacement, path)


def summary(stage, secure_selected, disabled):
    sections, categories = parse_blueprint(checked_file(stage / "blueprint.conf"))
    def count(group, name):
        return len(sections[name]) if group not in disabled else 0

    def selected(group, name):
        return group not in disabled and categories[name]

    def row(label, value):
        print(f"  {label:20} {value}")

    print("Applications")
    row("Homebrew casks", count("Applications", "homebrew-casks"))
    row("App Store apps", count("Applications", "app-store"))
    row("VS Code extensions", count("Applications", "vscode-extensions"))
    print("Homebrew")
    row("Formulae", count("Homebrew", "homebrew-packages"))
    print("Settings")
    row("macOS", sum(selected("macOS Settings", name) for name in GROUPS["macOS Settings"]))
    row("Git", count("Git", "git-configuration") if selected("Git", "git-configuration") else 0)
    for label, group, name in (
        ("SSH Configuration", "SSH Configuration", "ssh-configuration"),
        ("VS Code Settings", "VS Code Settings", "vscode-settings"),
        ("Shell / Zsh", "Shell", "shell-zsh"),
    ):
        row(label, "Yes" if selected(group, name) else "No")
    print("Workspace")
    row("Folders", count("Workspace", "workspace-folders"))
    row("Git repositories", count("Workspace", "git-repositories"))
    print("Secure Credentials")
    row("SSH identities", "Selected" if secure_selected and (stage / "secure.age").exists() else "No")


def fingerprint(path):
    if path.is_file() and not path.is_symlink():
        return digest(path.read_bytes())
    if not path.is_dir() or path.is_symlink():
        raise Invalid("unsafe publication path")
    value = hashlib.sha256()
    for child in sorted(path.rglob("*")):
        if child.is_symlink():
            raise Invalid("link in publication state")
        relative = child.relative_to(path).as_posix().encode()
        value.update(relative + b"\0")
        if child.is_file():
            value.update(digest(child.read_bytes()).encode())
        elif not child.is_dir():
            raise Invalid("special publication entry")
    return value.hexdigest()


def recover():
    if not RECOVERY.exists():
        return
    if RECOVERY.is_symlink() or not RECOVERY.is_dir():
        raise Invalid("unsafe publication recovery path")
    if any((RECOVERY / name).is_symlink() for name in
           ("complete", "incomplete", "preparing", "generated.old", "blueprint.old")):
        raise Invalid("link in publication recovery state")
    if (RECOVERY / "complete").is_file():
        completed = json.loads((RECOVERY / "complete").read_text())
        if (not isinstance(completed, dict) or
            set(completed) not in ({"generated", "blueprint"},
                                   {"generated", "blueprint", "prepared"}) or
            ("prepared" in completed and completed["prepared"] != "internal") or
            {item.name for item in RECOVERY.iterdir()} -
                {"complete", "generated.old", "blueprint.old"}):
            raise Invalid("unexpected completed publication state; manual review required")
        for name in ("generated", "blueprint"):
            old = RECOVERY / (name + ".old")
            if old.exists() or old.is_symlink():
                if old.is_symlink() or fingerprint(old) != completed[name]["old"]:
                    raise Invalid("previous local state changed; manual review required")
        shutil.rmtree(RECOVERY)
        return
    marker = RECOVERY / "incomplete"
    preparing = RECOVERY / "preparing"
    if not marker.is_file() and not preparing.is_file():
        legacy = RECOVERY / "marker.tmp"
        if {item.name for item in RECOVERY.iterdir()} == {"marker.tmp"} and legacy.is_file():
            previous = json.loads(legacy.read_text())
            if not isinstance(previous, dict) or set(previous) != {"generated", "blueprint"}:
                raise Invalid("invalid legacy publication marker")
            for name in ("generated", "blueprint"):
                current = CONFIG / ("generated" if name == "generated" else "blueprint.conf")
                record = previous[name]
                if (not isinstance(record, dict) or
                    set(record) != {"present", "dev", "ino", "old", "new"}):
                    raise Invalid("invalid legacy publication marker")
                if record["present"]:
                    if (not current.exists() or current.is_symlink() or
                        (current.stat().st_dev, current.stat().st_ino) !=
                        (record["dev"], record["ino"]) or
                        fingerprint(current) != record["old"]):
                        raise Invalid("local state changed; manual recovery required")
                elif current.exists() or current.is_symlink():
                    raise Invalid("local state appeared; manual recovery required")
            shutil.rmtree(RECOVERY)
            return
        raise Invalid("publication recovery marker missing; manual review required")
    if marker.is_file() and preparing.is_file():
        raise Invalid("conflicting publication recovery markers")
    old_generated = RECOVERY / "generated.old"
    old_blueprint = RECOVERY / "blueprint.old"
    try:
        previous = json.loads((marker if marker.is_file() else preparing).read_text())
        if not isinstance(previous, dict):
            raise ValueError()
        internal = previous.get("prepared") == "internal"
        if set(previous) != ({"generated", "blueprint", "prepared"} if internal
                            else {"generated", "blueprint"}):
            raise ValueError()
        for name in ("generated", "blueprint"):
            if (not isinstance(previous[name], dict) or
                set(previous[name]) != {"present", "dev", "ino", "old", "new"}):
                raise ValueError()
        prepared = (RECOVERY / "generated.new", RECOVERY / "blueprint.new")
        allowed = {"incomplete" if marker.is_file() else "preparing"}
        if internal:
            allowed.update(("generated.new", "blueprint.new"))
        if marker.is_file():
            allowed.update(("generated.old", "blueprint.old"))
        if {item.name for item in RECOVERY.iterdir()} - allowed:
            raise Invalid("unexpected publication recovery entry")
        if preparing.is_file() and not internal:
            raise Invalid("invalid preparing publication marker")
        for name, path in (("generated", prepared[0]), ("blueprint", prepared[1])):
            if internal and (path.exists() or path.is_symlink()):
                if path.is_symlink() or (name == "generated" and not path.is_dir()) or (
                    name == "blueprint" and not path.is_file()):
                    raise Invalid("unsafe prepared publication path")
                if marker.is_file() and fingerprint(path) != previous[name]["new"]:
                    raise Invalid("prepared publication state changed; manual review required")
        if preparing.is_file():
            for name in ("generated", "blueprint"):
                current = CONFIG / ("generated" if name == "generated" else "blueprint.conf")
                record = previous[name]
                if (not isinstance(record, dict) or
                    set(record) != {"present", "dev", "ino", "old", "new"}):
                    raise ValueError()
                if record["present"]:
                    if (not current.exists() or current.is_symlink() or
                        (current.stat().st_dev, current.stat().st_ino) !=
                        (record["dev"], record["ino"]) or
                        fingerprint(current) != record["old"]):
                        raise Invalid("local state changed during preparation; manual review required")
                elif current.exists() or current.is_symlink():
                    raise Invalid("local state appeared during preparation; manual review required")
            shutil.rmtree(RECOVERY)
            return
        for name, old in (("generated", old_generated), ("blueprint", old_blueprint)):
            current = CONFIG / ("generated" if name == "generated" else "blueprint.conf")
            visible = current.exists() or current.is_symlink()
            record = previous[name]
            if not isinstance(record, dict) or set(record) != {"present", "dev", "ino", "old", "new"}:
                raise ValueError()
            if visible and old.exists() and fingerprint(current) != record["new"]:
                raise Invalid("published state changed; manual recovery required")
            if record["present"]:
                if old.exists():
                    if fingerprint(old) != record["old"]:
                        raise Invalid("previous local state changed; manual recovery required")
                    if current.is_dir() and not current.is_symlink():
                        shutil.rmtree(current)
                    elif visible:
                        current.unlink()
                    os.rename(old, current)
                elif (not visible or
                      (current.stat().st_dev, current.stat().st_ino) !=
                      (record["dev"], record["ino"]) or
                      fingerprint(current) != record["old"]):
                    raise Invalid("previous local state unavailable; manual recovery required")
            elif visible:
                if fingerprint(current) != record["new"]:
                    raise Invalid("published state changed; manual recovery required")
                if current.is_dir():
                    shutil.rmtree(current)
                else:
                    current.unlink()
        shutil.rmtree(RECOVERY)
    except (OSError, ValueError) as exc:
        raise Invalid("publication recovery failed; manual recovery required") from exc


def publish(stage):
    require_runtime_workspace(workspace_stage_files(stage))
    recover()
    source_generated = stage / "generated"
    source_blueprint = stage / "blueprint.conf"
    if not source_generated.is_dir() or not source_blueprint.is_file():
        raise Invalid("staged local state incomplete")
    # The recovery directory owns preparation from its first written marker.
    new_generated = RECOVERY / "generated.new"
    new_blueprint = RECOVERY / "blueprint.new"
    claimed = False
    try:
        current_generated = CONFIG / "generated"
        current_blueprint = CONFIG / "blueprint.conf"
        if any(path.is_symlink() for path in (current_generated, current_blueprint)):
            raise Invalid("unsafe local state path")
        if current_generated.exists() and not current_generated.is_dir():
            raise Invalid("unsafe generated destination")
        if current_blueprint.exists() and not current_blueprint.is_file():
            raise Invalid("unsafe Blueprint destination")
        def identity(path, source):
            present = path.exists()
            return {"present": present, "dev": path.stat().st_dev if present else None,
                    "ino": path.stat().st_ino if present else None,
                    "old": fingerprint(path) if present else None,
                    "new": fingerprint(source)}
        record = json.dumps({"generated": identity(current_generated, source_generated),
                             "blueprint": identity(current_blueprint, source_blueprint),
                             "prepared": "internal"}).encode()
        os.mkdir(RECOVERY, 0o700)
        claimed = True
        marker = RECOVERY / "incomplete"
        write_file(RECOVERY / "preparing", record)
        shutil.copytree(source_generated, new_generated, symlinks=False)
        write_file(new_blueprint, checked_file(source_blueprint, 65536))
        os.chmod(new_generated, 0o700)
        os.chmod(new_blueprint, 0o600)
        for path in new_generated.rglob("*"):
            os.chmod(path, 0o700 if path.is_dir() else 0o600)
        if (fingerprint(new_generated) != json.loads(record)["generated"]["new"] or
            fingerprint(new_blueprint) != json.loads(record)["blueprint"]["new"]):
            raise Invalid("prepared publication state changed")
        os.replace(RECOVERY / "preparing", marker)
        if current_generated.exists():
            os.rename(current_generated, RECOVERY / "generated.old")
        if current_blueprint.exists():
            os.rename(current_blueprint, RECOVERY / "blueprint.old")
        os.rename(new_generated, current_generated)
        os.rename(new_blueprint, current_blueprint)
    except BaseException as exc:
        if claimed:
            if (RECOVERY / "incomplete").is_file() or (RECOVERY / "preparing").is_file():
                recover()
            elif RECOVERY.is_dir() and not any(RECOVERY.iterdir()):
                RECOVERY.rmdir()
        if isinstance(exc, (OSError, Invalid)):
            raise Invalid("publication failed; previous local state restored") from exc
        raise
    try:
        os.rename(marker, RECOVERY / "complete")
    except OSError as exc:
        recover()
        raise Invalid("publication failed; previous local state restored") from exc
    shutil.rmtree(RECOVERY)


def main():
    command, *args = sys.argv[1:]
    if command == "pack" and len(args) == 3:
        pack(Path(args[0]), Path(args[1]), args[2])
    elif command == "check-portability" and len(args) == 2:
        blueprint = checked_file(Path(args[0]) / "blueprint.conf", 65536)
        files = staged_payload(Path(args[0]), blueprint)
        selected_payload(files, blueprint, home=args[1])
        zsh = files.get("generated/shell/zshrc.snapshot")
        if zsh is not None and not zsh.startswith(b"MBT-ZSHRC-1\nstatus=eligible\n"):
            raise Invalid("selected Zsh snapshot is not eligible")
        portable_paths(files, args[1])
        validate_workspace(files, exact=True)
    elif command == 'capture-preview' and len(args) == 2:
        stage = Path(args[0])
        write_file(stage / '.capture-preview.conf', capture_preview(stage, args[1]))
    elif command == "unpack" and len(args) == 3:
        unpack(Path(args[0]), Path(args[1]), args[2])
    elif command == "narrow" and len(args) >= 1 and set(args[1:]) <= set(GROUPS):
        narrow(Path(args[0]), args[1:])
        deduplicate_applications(Path(args[0]))
    elif command == "summary" and len(args) >= 2 and args[1] in ("true", "false") and set(args[2:]) <= set(GROUPS):
        summary(Path(args[0]), args[1] == "true", args[2:])
    elif command == "publish" and len(args) == 1:
        publish(Path(args[0]))
    elif command == "recover" and not args:
        recover()
    else:
        raise Invalid("invalid Bundle helper command")


if __name__ == "__main__":
    try:
        main()
    except (Invalid, OSError, ValueError, TypeError, KeyError, UnicodeError,
            tarfile.TarError) as exc:
        print("Bundle error: " + (str(exc) if isinstance(exc, Invalid) else "operation failed"),
              file=sys.stderr)
        sys.exit(2)
