"""Homebrew Cask capability provider. Metadata is data, never executable Ruby.

Payload observation, current installation, installed cleanup and privilege are
separate contracts. Homebrew alone performs lifecycle operations. All subprocess
observations below are public, read-only interfaces.
"""
from functools import wraps
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request
import xml.etree.ElementTree as ET
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'core'))
from external_tool import result

LABEL = re.compile(r'[A-Za-z0-9][A-Za-z0-9_-]*(?:\.[A-Za-z0-9][A-Za-z0-9_-]*)+')
NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9+_.@-]*')
UNSUPPORTED = 'cask_execution_requirements_unsupported'
CONFLICT = 'cask_target_conflict'
OBSERVATION = 'cask_metadata_unavailable'

# Explicit public types and their bounded standard destinations, not a wildcard
# allowing every artifact with a target. Generic artifact is checked separately.
RELOCATED = {
    'app': ('Applications',), 'suite': ('Applications',),
    'font': ('Library/Fonts',), 'colorpicker': ('Library/ColorPickers',),
    'dictionary': ('Library/Dictionaries',), 'input_method': ('Library/Input Methods',),
    'internet_plugin': ('Library/Internet Plug-Ins',),
    'keyboard_layout': ('Library/Keyboard Layouts',), 'prefpane': ('Library/PreferencePanes',),
    'mdimporter': ('Library/Spotlight',), 'qlplugin': ('Library/QuickLook',),
    'screen_saver': ('Library/Screen Savers',), 'service': ('Library/Services',),
    'audio_unit_plugin': ('Library/Audio/Plug-Ins/Components',),
    'vst_plugin': ('Library/Audio/Plug-Ins/VST',), 'vst3_plugin': ('Library/Audio/Plug-Ins/VST3',),
}
LINKED = {'binary', 'manpage', 'bash_completion', 'zsh_completion', 'fish_completion', 'pwsh_completion'}
LIFECYCLE = {'quit', 'launchctl', 'pkgutil', 'delete', 'trash', 'rmdir', 'login_item'}
GENERATED_COMPLETIONS = 'generate_completions_from_executable'


def completion_predicates(args, prefix):
    """Public generated-completion declaration, never run the generator here.

    Restrict it to completion commands from a separately declared executable.
    Homebrew owns generation and its sandbox; outputs are observable regular files.
    """
    require(isinstance(args, list) and 2 <= len(args) <= 4)
    options = args[-1] if isinstance(args[-1], dict) else {}
    commands = args[:-1] if isinstance(args[-1], dict) else args
    require(commands and all(clean(v) for v in commands))
    executable = str(path(commands[0], absolute=commands[0].startswith('/')))
    require(not set(options) - {'base_name', 'shell_parameter_format', 'shells'})
    formatting = options.get('shell_parameter_format')
    require(formatting in (None, 'arg', 'clap', 'click', 'cobra', 'flag', 'none', 'typer'))
    require(commands[1:] in (['completion'], ['completions']) or
            (not commands[1:] and formatting in ('clap', 'click', 'cobra', 'typer')))
    name = options.get('base_name') or Path(executable).name
    require(isinstance(name, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', name))
    shells = options.get('shells') or (['bash', 'zsh', 'fish', 'pwsh'] if formatting in ('cobra', 'typer')
                                      else ['bash', 'zsh', 'fish'])
    require(isinstance(shells, list) and bool(shells) and len(set(shells)) == len(shells)
            and all(s in ('bash', 'zsh', 'fish', 'pwsh') for s in shells))
    targets = {'bash': prefix / 'etc/bash_completion.d' / name,
               'zsh': prefix / 'share/zsh/site-functions' / ('_' + name),
               'fish': prefix / 'share/fish/vendor_completions.d' / (name + '.fish'),
               'pwsh': prefix / 'share/pwsh/completions' / ('_' + name + '.ps1')}
    return [{'kind': 'file', 'artifact': GENERATED_COMPLETIONS, 'path': str(targets[s]),
             'generator': {'executable': executable, 'commands': commands[1:],
                           'format': formatting, 'shell': s}} for s in shells]


class Unsafe(Exception):
    def __init__(self, condition=UNSUPPORTED, diagnostic=None):
        self.condition = condition
        self.diagnostic = diagnostic


def require(value, condition=UNSUPPORTED, detail=None):
    if not value:
        raise Unsafe(condition, {'condition': detail} if detail else None)


def contract(primitive):
    """Bounded, non-sensitive context on the existing provider result."""
    def decorate(function):
        @wraps(function)
        def checked(*args, **kwargs):
            try:
                return function(*args, **kwargs)
            except Unsafe as exc:
                context = exc.diagnostic or {}
                context.setdefault('primitive', primitive)
                context.setdefault('condition', 'ownership_unproven' if exc.condition == CONFLICT else
                                   'unsupported_capability' if exc.condition == UNSUPPORTED else 'observation_failed')
                exc.diagnostic = context
                raise
            except (OSError, ValueError, TypeError, KeyError, IndexError, AttributeError, subprocess.SubprocessError):
                raise Unsafe(OBSERVATION, {'primitive': primitive, 'condition': 'observation_failed'}) from None
        return checked
    return decorate


def clean(value):
    return isinstance(value, str) and 0 < len(value) <= 4096 and all(ord(c) >= 32 and ord(c) != 127 for c in value)


def values(value):
    value = [value] if isinstance(value, str) else value
    require(isinstance(value, list) and len(value) <= 128 and all(clean(v) for v in value))
    return value


def path(value, absolute=True):
    require(clean(value) and not any(c in value for c in '*?[]{}'))
    require(value == '/' or not any(p in ('', '.', '..') for p in value.split('/')[1:]))
    require(absolute or not any(p in ('', '.', '..') for p in value.split('/')))
    value = Path(value).expanduser()
    require(value.is_absolute() if absolute else not value.is_absolute())
    return value


def beneath(value, root):
    return value != root and value.is_relative_to(root)


def writable_parent(target):
    parent = target.parent
    while not os.path.lexists(parent) and parent != parent.parent:
        parent = parent.parent
    require(parent.is_dir() and not parent.is_symlink(), CONFLICT)
    return os.access(parent, os.W_OK | os.X_OK)


def portable_target(target, prefix):
    roots = {'applications': Path('/Applications'), 'home': Path.home(),
             'prefix': prefix, 'library': Path('/Library'), 'system': Path('/')}
    for name, root in roots.items():
        if beneath(target, root):
            return {'root': name, 'relative': str(target.relative_to(root))}
    raise Unsafe()


def target_from_capture(value, prefix):
    roots = {'applications': Path('/Applications'), 'home': Path.home(),
             'prefix': prefix, 'library': Path('/Library'), 'system': Path('/')}
    require(isinstance(value, dict) and set(value) == {'root', 'relative'} and value['root'] in roots)
    return roots[value['root']] / path(value['relative'], absolute=False)


def read_json(value):
    require(not value.is_symlink() and value.is_file(), OBSERVATION)
    require(value.stat().st_size <= 1024 * 1024, OBSERVATION)
    require(value.stat().st_uid in (0, os.getuid()) and not value.stat().st_mode & 0o022, OBSERVATION)
    data = json.loads(value.read_text())
    require(isinstance(data, dict), OBSERVATION)
    return data


class PublicObserver:
    def read(self, arguments):
        observed = subprocess.run(arguments, env=dict(os.environ, HOMEBREW_NO_AUTO_UPDATE='1',
                                  HOMEBREW_NO_SUDO='1'), stdin=subprocess.DEVNULL,
                                  capture_output=True, timeout=30, check=False)
        require(observed.returncode == 0, OBSERVATION)
        require(len(observed.stdout) <= 4 * 1024 * 1024, OBSERVATION)
        return observed.stdout

    @contract('pkgutil')
    def packages(self, selectors):
        inventory = self.read(['/usr/sbin/pkgutil', '--pkgs']).decode().splitlines()
        records = []
        for selector in selectors:
            # Exact IDs only: Homebrew's unbounded regexp removal is not equivalent
            # to ownership of every matching package on this machine.
            require(LABEL.fullmatch(selector))
            if selector not in inventory:
                records.append({'id': selector, 'present': False, 'paths': []})
                continue
            info = plistlib.loads(self.read(['/usr/sbin/pkgutil', '--pkg-info-plist', selector]))
            require(info.get('pkgid') == selector and info.get('volume') == '/', OBSERVATION)
            base = path('/' + info.get('install-location', '').lstrip('/'))
            listing = self.read(['/usr/sbin/pkgutil', '--only-files', '--files', selector]).decode().splitlines()
            require(bool(listing) and len(listing) <= 50000, OBSERVATION)
            files = []
            for entry in listing:
                entry = entry.removeprefix('./')
                relative = path(entry, absolute=False)
                files.append(str(base / relative))
            records.append({'id': selector, 'present': True, 'paths': files,
                            'location': str(base), 'version': str(info.get('pkg-version', ''))})
        return records

    @contract('pkgutil')
    def package_install_payloads(self, row, selectors):
        """Checksum-bound, inert inspection of a root-app native package.

        Never run installer/scripts. Unsupported layouts stay fail closed.
        Temporary artifacts are private and removed on every handled return.
        """
        require(re.fullmatch(r'[0-9a-f]{64}', row.get('sha256', '')))
        source = urlsplit(row.get('url', ''))
        require(source.scheme == 'https' and source.hostname and not source.username and not source.password)
        with tempfile.TemporaryDirectory(prefix='macseed-package-inspect-') as directory:
            root = Path(directory)
            archive = root / 'source.pkg'
            digest, size, started = hashlib.sha256(), 0, time.monotonic()
            with urllib.request.urlopen(row['url'], timeout=30) as response, archive.open('wb') as output:
                destination = urlsplit(response.geturl())
                require(destination.scheme == 'https' and destination.hostname and not destination.username and not destination.password)
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    size += len(chunk)
                    require(size <= 128 * 1024 * 1024 and time.monotonic() - started <= 60, OBSERVATION)
                    digest.update(chunk); output.write(chunk)
            require(digest.hexdigest() == row['sha256'], OBSERVATION)
            expanded = root / 'expanded'
            self.read(['/usr/sbin/pkgutil', '--expand-full', str(archive), str(expanded)])
            records, payloads, count, total = set(), [], 0, 0
            for location, directories, files in os.walk(expanded, followlinks=False):
                require(len(Path(location).relative_to(expanded).parts) <= 24, OBSERVATION)
                count += len(directories) + len(files)
                require(count <= 8192, OBSERVATION)
                for name in files:
                    target = Path(location) / name
                    total += target.lstat().st_size
                    require(total <= 512 * 1024 * 1024, OBSERVATION)
                    if name != 'PackageInfo':
                        continue
                    require(not target.is_symlink() and target.stat().st_size <= 65536, OBSERVATION)
                    try:
                        info = ET.fromstring(target.read_bytes())
                    except ET.ParseError:
                        raise Unsafe(OBSERVATION) from None
                    require(info.tag == 'pkg-info')
                    identifier = info.get('identifier')
                    require(identifier in selectors and identifier not in records)
                    records.add(identifier)
                    application = path(info.get('install-location'))
                    require(application.parent == Path('/Applications') and application.suffix == '.app')
                    payload = target.parent / 'Payload'
                    require(bundle_matches(payload), OBSERVATION)
                    identity = plistlib.loads((payload / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
                    payloads.append({'kind': 'app', 'path': str(application), 'package': identifier, 'bundle_id': identity})
            require(records == set(selectors) and len(payloads) > 0)
            return payloads

    @contract('pkgutil')
    def package_ownership(self, packages):
        selected = {record['id'] for record in packages}
        filenames = sorted({f for record in packages for f in record['paths'] if os.path.lexists(f)})
        require(len(filenames) <= 2048)
        for filename in filenames:
            if not os.path.lexists(filename):
                continue
            raw = self.read(['/usr/sbin/pkgutil', '--file-info-plist', filename])
            # No owner response for an existing purported receipt file is not
            # evidence that it is exclusively owned by this cask.
            require(bool(raw.strip()), CONFLICT)
            owners = set()
            # pkgutil emits one plist per package, not necessarily one outer array.
            chunks = re.findall(rb'<\?xml.*?</plist>', raw, re.S)
            require(bool(chunks), OBSERVATION)
            for chunk in chunks:
                data = plistlib.loads(chunk)
                require(isinstance(data, dict), OBSERVATION)
                if data.get('pkgid'):
                    owners.add(data['pkgid'])
                for record in data.get('pkgs', []):
                    require(isinstance(record, dict) and isinstance(record.get('pkgid'), str), OBSERVATION)
                    owners.add(record['pkgid'])
            require(bool(owners) and owners <= selected, CONFLICT)

    def launch_roots(self):
        return (Path.home() / 'Library/LaunchAgents', Path.home() / 'Library/LaunchDaemons',
                Path('/Library/LaunchAgents'), Path('/Library/LaunchDaemons'))

    @contract('launchctl')
    def launchctl(self, labels, payloads, orphan_labels=(), xpc_labels=()):
        home = Path.home()
        domains = ('gui/' + str(os.getuid()), 'user/' + str(os.getuid()), 'system')
        # Explicit domains are authoritative. launchctl list depends on the
        # caller's inherited bootstrap namespace and is not a required observer.
        inventories = [self.read(['/bin/launchctl', 'print', domain]).decode() for domain in domains]
        selected = []
        for raw in inventories:
            rows = raw.splitlines()
            starts = [(i, re.fullmatch(r'([ \t]*)services = \{[ \t]*', line))
                      for i, line in enumerate(rows)]
            starts = [(i, match) for i, match in starts if match]
            require(len(starts) == 1, 'cask_launchctl_observation_failed', 'malformed_observation')
            start, match = starts[0]
            end = next((i for i in range(start + 1, len(rows))
                        if rows[i].rstrip() == match[1] + '}'), None)
            require(end is not None, 'cask_launchctl_observation_failed', 'malformed_observation')
            present = set()
            for line in rows[start + 1:end]:
                # Other services/records cannot invalidate a selected label.
                mentioned = set(line.split()) & set(labels)
                if not mentioned:
                    continue
                record = re.fullmatch(r'\s*[0-9]+\s+(?:-|[-]?[0-9]+)\s+(\S+)\s*', line)
                require(record is not None and record[1] in labels,
                        'cask_launchctl_observation_failed', 'malformed_observation')
                require(record[1] not in present, CONFLICT, 'ownership_ambiguous')
                present.add(record[1])
            selected.append(present)
        roots = self.launch_roots()
        plists = {label: {} for label in labels}
        for root in roots:
            if not root.exists():
                continue
            require(root.is_dir() and not root.is_symlink(), CONFLICT, 'ownership_ambiguous')
            candidates = [p for p in root.iterdir() if p.suffix == '.plist']
            require(len(candidates) <= 2048, OBSERVATION, 'observation_limit')
            for target in candidates:
                try:
                    data = plistlib.loads(target.read_bytes())
                    require(isinstance(data, dict), OBSERVATION, 'malformed_observation')
                except (OSError, ValueError, plistlib.InvalidFileException, Unsafe):
                    # An unknown unrelated file is not attributed to this label.
                    # A selected canonical filename remains a required observation.
                    require(target.stem not in labels, OBSERVATION, 'observation_failed')
                    continue
                label = data.get('Label')
                if label not in labels:
                    require(target.stem not in labels, CONFLICT, 'conflicting_plist')
                    continue
                require(not target.is_symlink() and target.is_file(), CONFLICT, 'ownership_ambiguous')
                require(target.stat().st_uid in (0, os.getuid()) and not target.stat().st_mode & 0o022,
                        CONFLICT, 'conflicting_plist')
                arguments = data.get('ProgramArguments')
                require(arguments is None or (isinstance(arguments, list) and all(clean(v) for v in arguments)),
                        OBSERVATION, 'malformed_observation')
                command = data.get('Program') or (arguments or [None])[0]
                require(clean(command), OBSERVATION, 'malformed_observation')
                require(any(beneath(path(command), Path(p['path'])) for p in payloads
                            if p['kind'] in ('app', 'suite', 'bundle')), CONFLICT, 'foreign_target')
                plists[label][str(target)] = command
        privileged = False
        for label in labels:
            concrete = {domain for domain, observed in zip(domains, selected) if label in observed}
            require(len(concrete) <= 1, CONFLICT, 'ownership_ambiguous')
            owned_plists = plists[label]
            require(len(owned_plists) <= 1, CONFLICT, 'ownership_ambiguous')
            privileged |= any(filename.startswith('/Library/') for filename in owned_plists)
            for domain in concrete:
                raw = self.read(['/bin/launchctl', 'print', domain + '/' + label]).decode()
                programs = re.findall(r'^\s*program = (/[^\r\n]+)$', raw, re.M)
                require(len(programs) == 1, 'cask_launchctl_observation_failed', 'malformed_observation')
                program = path(programs[0])
                if owned_plists:
                    matching = [filename for filename, command in owned_plists.items() if command == str(program)]
                    allowed_roots = (Path('/Library/LaunchDaemons'),) if domain == 'system' else (
                        home / 'Library/LaunchAgents', home / 'Library/LaunchDaemons', Path('/Library/LaunchAgents'))
                    require(any(Path(filename).parent in allowed_roots for filename in matching), CONFLICT, 'conflicting_plist')
                else:
                    # An inactive orphan is bounded by the installed lifecycle and
                    # exact missing payload. No removal is performed here.
                    require(domain != 'system', CONFLICT, 'ownership_unproven')
                    candidates = [Path(p['path']) for p in payloads if p['kind'] == 'app'
                                  and not os.path.lexists(p['path']) and beneath(program, Path(p['path']))
                                  and beneath(program.resolve(strict=False), Path(p['path']).resolve(strict=False))]
                    require(len(candidates) == 1, CONFLICT, 'foreign_target')
                    types = re.findall(r'^\s*type = ([^\r\n]+)$', raw, re.M)
                    require(label in orphan_labels or (label in xpc_labels and types == ['XPCService']),
                            CONFLICT, 'ownership_unproven')
                    if types == ['XPCService']:
                        sources = re.findall(r'^\s*path = (/[^\r\n]+)$', raw, re.M)
                        identities = re.findall(r'^\s*bundle id = ([^\r\n]+)$', raw, re.M)
                        require(len(sources) == 1 and identities == [label]
                                and program.parent.parent == path(sources[0]) / 'Contents',
                                CONFLICT, 'ownership_unproven')
                    relative = program.relative_to(candidates[0]).parts
                    require((len(relative) == 3 and relative[:2] == ('Contents', 'MacOS')) or
                            (len(relative) == 6 and relative[:2] == ('Contents', 'XPCServices')
                             and relative[2].endswith('.xpc') and relative[3:5] == ('Contents', 'MacOS')),
                            CONFLICT, 'ownership_unproven')
                    states = re.findall(r'^\s*state = ([^\r\n]+)$', raw, re.M)
                    require(len(states) == 1, 'cask_launchctl_observation_failed', 'malformed_observation')
                    require(states[0] in ('not running', 'waiting', 'exited', 'disabled') and
                            not re.search(r'^\s*pid = ', raw, re.M) and not os.path.lexists(program),
                            CONFLICT, 'live_ownership_unproven')
            require(not os.path.lexists(Path.cwd() / label), CONFLICT, 'conflicting_plist')
        return privileged

    @contract('login_item')
    def login_items(self, names, apps, orphan_names=()):
        from homebrew_automation import AutomationUnavailable, login_items
        try:
            pairs = login_items()
        except AutomationUnavailable as exc:
            raise Unsafe('cask_authorization_required' if exc.authorization else OBSERVATION,
                         {'primitive': 'login_item', 'condition': exc.condition}) from None
        seen = {}
        for name, target in pairs:
            if name not in names:
                continue
            require(clean(name) and name not in seen and (target is None or clean(target)),
                    OBSERVATION, 'identity_ambiguous')
            seen[name] = target
        for name in names:
            expected = [Path(app['path']) for app in apps if Path(app['path']).stem == name]
            require(len(expected) == 1, CONFLICT, 'ownership_ambiguous')
            if name not in seen:
                continue
            target = seen[name]
            if target is None:
                require(name in orphan_names and not os.path.lexists(expected[0]), CONFLICT, 'ownership_unproven')
            else:
                require(target == str(expected[0]), CONFLICT, 'foreign_target')

    def platform(self):
        return platform.machine(), self.read(['/usr/bin/sw_vers', '-productVersion']).decode().strip()

    def conflicts(self, metadata):
        for kind, names in (metadata or {}).items():
            require(kind in ('cask', 'formula'))
            names = values(names)
            require(all(NAME.fullmatch(n) for n in names))
            installed = self.read(['brew', 'list', '--' + kind]).decode().splitlines()
            require(not set(names) & set(installed), CONFLICT)

    def cask(self, token):
        data = json.loads(self.read(['brew', 'info', '--json=v2', '--cask', token]))
        require(isinstance(data.get('casks'), list) and len(data['casks']) == 1, OBSERVATION)
        require(data['casks'][0].get('token') == token, OBSERVATION)
        return data['casks'][0]


def artifact_rows(artifacts):
    require(isinstance(artifacts, list) and bool(artifacts))
    for artifact in artifacts:
        require(isinstance(artifact, dict))
        keys = set(artifact) - {'target'}
        require(len(keys) == 1)
        yield next(iter(keys)), artifact


def lifecycle(artifacts):
    normalized = {}
    for kind, artifact in artifact_rows(artifacts):
        if kind == 'zap':
            continue
        if kind != 'uninstall':
            require(kind in RELOCATED or kind in LINKED or kind in ('pkg', 'command_wrapper', 'artifact', GENERATED_COMPLETIONS))
            continue
        require('target' not in artifact and isinstance(artifact[kind], list))
        for directive in artifact[kind]:
            require(isinstance(directive, dict) and not set(directive) - LIFECYCLE)
            for key, value in directive.items():
                entries = values(value)
                if key in ('quit', 'launchctl', 'pkgutil'):
                    require(all(LABEL.fullmatch(v) for v in entries))
                elif key in ('delete', 'trash', 'rmdir'):
                    entries = [str(path(v)) for v in entries]
                else:
                    require(all('/' not in v and len(v) <= 255 for v in entries))
                normalized.setdefault(key, []).extend(entries)
    return {k: sorted(set(v)) for k, v in normalized.items()}


def package_selectors(artifacts):
    selectors = []
    for kind, artifact in artifact_rows(artifacts):
        if kind != 'uninstall':
            continue
        require(isinstance(artifact[kind], list))
        for directive in artifact[kind]:
            require(isinstance(directive, dict))
            if 'pkgutil' in directive:
                selectors.extend(values(directive['pkgutil']))
    require(bool(selectors) and all(LABEL.fullmatch(v) for v in selectors))
    return sorted(set(selectors))


@contract('metadata')
def predicates(row, prefix, observer):
    payloads, packages = [], []
    home = Path.home()
    for kind, artifact in artifact_rows(row['artifacts']):
        if kind in ('uninstall', 'zap'):
            continue
        args = artifact[kind]
        require(isinstance(args, list) and bool(args))
        if kind == GENERATED_COMPLETIONS:
            require('target' not in artifact)
            payloads.extend(completion_predicates(args, prefix))
            continue
        if kind == 'pkg':
            require(len(args) == 1 and clean(args[0]) and args[0].endswith('.pkg'))
            path(args[0], absolute=False)
            selectors = package_selectors(row['artifacts'])
            packages = observer.packages(selectors)
            for record in packages:
                # Receipt identity is one required predicate, not payload proof.
                payloads.append({'kind': 'receipt', 'id': record['id'], 'present': record['present']})
                if not record['present']:
                    continue
                apps = set()
                for filename in [record.get('location', ''), *record['paths']]:
                    parts = Path(filename).parts
                    for index, part in enumerate(parts):
                        if part.endswith('.app'):
                            apps.add(str(Path(*parts[:index + 1])))
                            break
                if apps:
                    payloads.extend({'kind': 'app', 'path': str(path(a)), 'package': record['id']} for a in sorted(apps))
                    external = [f for f in record['paths'] if not any(Path(f).is_relative_to(Path(a)) for a in apps)
                                and not any(component in ('Preferences', 'Caches', 'Logs', 'Application Support')
                                            for component in Path(f).parts)]
                    payloads.extend({'kind': 'file', 'path': str(path(f)), 'package': record['id']} for f in external)
                else:
                    # Do not make mutable preferences/cache/logs required payload.
                    files = [f for f in record['paths'] if not any(component in (
                        'Preferences', 'Caches', 'Logs', 'Application Support') for component in Path(f).parts)]
                    require(bool(files))
                    payloads.extend({'kind': 'file', 'path': str(path(f)), 'package': record['id']} for f in files)
            continue
        target = path(artifact.get('target'))
        require(len(target.parts) > 2)
        if kind in RELOCATED:
            require(len(args) <= 2 and clean(args[0]))
            path(args[0], absolute=False)
            options = args[1] if len(args) == 2 else {}
            require(isinstance(options, dict) and not set(options) - {'target'})
            require(options.get('target') or Path(args[0]).name == target.name)
            if kind == 'app':
                require(args[0].endswith('.app') and target.suffix == '.app')
            if options.get('target'):
                require(clean(options['target']) and Path(options['target']).name == target.name)
                if options['target'].startswith('/'):
                    require(options['target'] == str(target))
                else:
                    path(options['target'], absolute=False)
            require(any(target.parent == root / directory for directory in RELOCATED[kind]
                        for root in (Path('/'), home)))
            payloads.append({'kind': kind if kind in ('app', 'suite') else 'bundle' if target.suffix in (
                '.bundle', '.plugin', '.prefPane', '.qlgenerator', '.saver', '.component', '.vst', '.vst3', '.service', '.mdimporter',
                '.dictionary', '.colorPicker', '.workflow', '.app') else 'file',
                             'artifact': kind, 'path': str(target)})
        elif kind in LINKED or kind == 'command_wrapper':
            require(beneath(target, prefix / 'bin') if kind in ('binary', 'command_wrapper') else
                    beneath(target, prefix / 'share') or beneath(target, prefix / 'etc'))
            require(len(args) <= 2)
            options = args[1] if len(args) == 2 else {}
            require(isinstance(options, dict))
            if kind == 'command_wrapper':
                require(NAME.fullmatch(args[0]) and target.name == args[0] and not set(options) - {'executable', 'args', 'env'})
                require(clean(options.get('executable')))
                require(isinstance(options.get('args', []), list) and all(clean(a) for a in options.get('args', [])))
                environment = options.get('env', {})
                require(isinstance(environment, dict) and all(re.fullmatch(r'[A-Z_][A-Z_0-9]*', k) and clean(v)
                        and k in ('LANG', 'LC_ALL', 'LC_CTYPE', 'TZ', 'TERM')
                        for k, v in environment.items()))
                executable = options['executable']
            else:
                require(not set(options) - {'target'} and clean(args[0]))
                if options.get('target'):
                    require(clean(options['target']) and Path(options['target']).name == target.name)
                    if options['target'].startswith('/'):
                        require(options['target'] == str(target))
                    else:
                        path(options['target'], absolute=False)
                executable = args[0]
            if executable.startswith('/'):
                executable = str(path(executable))
            else:
                path(executable, absolute=False)
            payloads.append({'kind': 'wrapper' if kind == 'command_wrapper' else 'link',
                             'artifact': kind, 'path': str(target), 'source': executable,
                             'executable': kind in ('binary', 'command_wrapper')})
        elif kind == 'artifact':
            require(len(args) == 2 and isinstance(args[1], dict) and set(args[1]) == {'target'})
            require(str(target) == args[1]['target'] and
                    (beneath(target, prefix / 'share') or beneath(target, home / 'Library')))
            payloads.append({'kind': 'file', 'artifact': kind, 'path': str(target)})
        else:
            raise Unsafe()
    require(bool(payloads))
    unique = {}
    for predicate in payloads:
        key = (predicate['kind'], predicate.get('path') or predicate['id'])
        if key in unique:
            require(predicate['kind'] == 'receipt' or ('package' in predicate and 'package' in unique[key]))
            if predicate['kind'] == 'receipt':
                require(predicate['present'] == unique[key]['present'], OBSERVATION)
        else:
            unique[key] = predicate
    payloads = list(unique.values())
    targets = [p['path'] for p in payloads if 'path' in p]
    require(len(targets) == len(set(targets)))
    for predicate in payloads:
        if predicate.get('artifact') == GENERATED_COMPLETIONS:
            executable = predicate['generator']['executable']
            require(any(p['kind'] == 'link' and p['executable'] and p['source'] == executable for p in payloads)
                    or any(p['kind'] == 'app' and
                           (beneath(Path(executable), Path(p['path'])) if executable.startswith('/') else
                            executable.startswith(Path(p['path']).name + '/Contents/MacOS/')) for p in payloads))
        if predicate['kind'] in ('link', 'wrapper') and predicate['source'].startswith('/'):
            source = Path(predicate['source'])
            require(source.is_file() or any(p['kind'] == 'app' and beneath(source, Path(p['path'])) for p in payloads))
    # An absent package receipt is a nonempty unresolved payload requirement,
    # never an empty set that can satisfy a registered cask.
    return payloads, packages


def bundle_matches(target, app=True, expected_id=None):
    require(target.is_dir() and not target.is_symlink(), CONFLICT)
    info = target / 'Contents/Info.plist'
    if not info.exists():
        return False
    require(not info.is_symlink(), CONFLICT)
    data = plistlib.loads(info.read_bytes())
    identifier, executable = data.get('CFBundleIdentifier'), data.get('CFBundleExecutable')
    require(isinstance(identifier, str) and LABEL.fullmatch(identifier), CONFLICT)
    require(expected_id is None or identifier == expected_id, CONFLICT)
    if not app and executable is None:
        return True
    require(clean(executable) and '/' not in executable, CONFLICT)
    binary = target / 'Contents/MacOS' / executable
    if binary.exists():
        require(beneath(binary.resolve(), target.resolve()), CONFLICT)
    return binary.is_file() and os.access(binary, os.X_OK)


@contract('payload')
def observe(payloads, row, prefix):
    require(bool(payloads))
    missing, owned = [], []
    root = prefix / 'Caskroom' / row['token']
    for predicate in payloads:
        if predicate['kind'] == 'receipt':
            if not predicate['present']:
                missing.append(predicate)
            continue
        target = Path(predicate['path'])
        try:
            target.lstat()
        except FileNotFoundError:
            missing.append(predicate)
            continue
        kind = predicate['kind']
        if kind in ('app', 'suite', 'bundle'):
            satisfied = bundle_matches(target, kind == 'app', predicate.get('bundle_id'))
            if kind == 'suite':
                members = list(target.glob('*.app'))
                satisfied = bool(members) and all(bundle_matches(member) for member in members)
                required_members = predicate.get('members', [])
                require(isinstance(required_members, list) and len(required_members) <= 2048, CONFLICT)
                for member in required_members:
                    require(isinstance(member, dict) and isinstance(member.get('name'), str)
                            and '/' not in member['name'] and member['name'].endswith('.app')
                            and isinstance(member.get('bundle_id'), str)
                            and bool(LABEL.fullmatch(member['bundle_id'])), CONFLICT)
                    required = target / member['name']
                    satisfied &= required.is_dir() and bundle_matches(required, expected_id=member['bundle_id'])
        elif kind in ('link', 'wrapper'):
            require(target.is_symlink(), CONFLICT)
            linked = Path(os.path.abspath(target.parent / os.readlink(target)))
            source = predicate['source']
            if kind == 'wrapper' or not source.startswith('/'):
                require(beneath(linked, root), CONFLICT)
                if linked.exists():
                    require(beneath(linked.resolve(), root.resolve()), CONFLICT)
            else:
                require(str(linked) == source, CONFLICT)
            satisfied = target.is_file() and (not predicate['executable'] or os.access(target, os.X_OK))
            if source.startswith('/'):
                source_path = Path(source)
                satisfied &= source_path.is_file() and (not predicate['executable'] or os.access(source_path, os.X_OK))
        else:
            require(target.is_file() and not target.is_symlink(), CONFLICT)
            if predicate.get('artifact') == GENERATED_COMPLETIONS:
                require(target.stat().st_uid == os.getuid() and not target.stat().st_mode & 0o022, CONFLICT)
            satisfied = target.stat().st_size > 0
        (owned if satisfied else missing).append(predicate)
    require(any(p['kind'] != 'receipt' for p in payloads) or bool(missing))
    return missing, owned


@contract('historical_metadata')
def installed_contract(row, prefix):
    """Prefer Macseed's own observation record. Legacy receipt import is inert,
    structurally checked compatibility evidence, not a Ruby API/version rule.
    Missing/unknown receipt schemas fail closed. Never inspect Ruby snapshots.
    """
    records = Path.home() / 'Library/Application Support/Macseed/Homebrew/contracts' / (row['token'] + '.json')
    if records.exists():
        record = read_json(records)
        if record.get('installed') == row.get('installed'):
            require(record.get('contract') == 1 and record.get('token') == row['token'], OBSERVATION)
            return record['artifacts'], record.get('appdir')
    root = prefix / 'Caskroom' / row['token']
    require(not root.is_symlink() and root.resolve().is_relative_to(prefix.resolve()), CONFLICT)
    receipt = read_json(root / '.metadata/INSTALL_RECEIPT.json')
    require(receipt.get('uninstall_flight_blocks') is False)
    source = receipt.get('source', {})
    require(source.get('tap') == row['tap'] and source.get('version') == row['installed'])
    artifacts = receipt.get('uninstall_artifacts')
    lifecycle(artifacts)
    config = read_json(root / '.metadata/config.json')
    require(not set(config) - {'default', 'env', 'explicit'}, OBSERVATION)
    appdir = None
    for key in ('default', 'env', 'explicit'):
        require(isinstance(config.get(key, {}), dict), OBSERVATION)
        appdir = config.get(key, {}).get('appdir', appdir)
    return artifacts, appdir


@contract('lifecycle')
def qualify_cleanup(directives, payloads, packages, observer, orphan=None):
    privileged = False
    for key, entries in directives.items():
        if key == 'quit':
            continue
        if key == 'launchctl':
            try:
                privileged |= observer.launchctl(entries, payloads, (orphan or {}).get("launchctl", ()),
                                                  (orphan or {}).get("xpc_launchctl", ()))
            except Unsafe as exc:
                if exc.condition == OBSERVATION:
                    raise Unsafe('cask_launchctl_observation_failed', exc.diagnostic) from None
                raise
        elif key == 'pkgutil':
            require(set(entries) == {p['id'] for p in packages})
            require(all(p['present'] for p in packages), CONFLICT)
            observer.package_ownership(packages)
            privileged = True
        elif key == 'login_item':
            observer.login_items(entries, [p for p in payloads if p['kind'] == 'app'], (orphan or {}).get("login_item", ()))
        else:
            for entry in entries:
                target = path(entry)
                declared = [Path(p['path']) for p in payloads if 'path' in p]
                packaged = {f for record in packages for f in record['paths']}
                # Exact absent preferences are a bounded, explicit lifecycle effect.
                # Existing user/config data needs independent ownership; no glob,
                # parent-directory deletion or inferred namespace ownership.
                preference = target.parent == Path('/Library/Preferences') and target.suffix == '.plist'
                require(target in declared or str(target) in packaged or
                        (preference and not os.path.lexists(target)) or
                        (target.parent in (Path('/usr/local/bin'), Path('/opt/homebrew/bin')) and
                         target.is_symlink() and any(p['kind'] == 'app' and
                             beneath(target.resolve(strict=False), Path(p['path'])) for p in payloads)), CONFLICT)
                if target.is_symlink():
                    require((target in declared and any(p['kind'] in ('link', 'wrapper') and p.get('path') == entry for p in payloads)) or
                            any(p['kind'] == 'app' and beneath(target.resolve(strict=False), Path(p['path'])) for p in payloads), CONFLICT)
                privileged |= key == 'delete' or not writable_parent(target)
    return privileged


def version_tuple(value):
    require(isinstance(value, str) and re.fullmatch(r'\d+(?:\.\d+){0,3}', value))
    return tuple(int(v) for v in value.split('.')) + (0,) * (4 - len(value.split('.')))


@contract('requirements')
def requirements(row, observer, operation=None):
    require(row.get('tap') == 'homebrew/cask' and row.get('disabled') is False)
    require(not row.get('container') and not row.get('rename'))
    # Public Homebrew caveats are installation information, not executable
    # cleanup directives. Native package installation is distinct from activation.
    # Keep Repair conservative and keep Rosetta requirements independently blocked.
    caveats = row.get('caveats')
    native_install = operation == 'install' and any(kind == 'pkg' for kind, _ in artifact_rows(row['artifacts']))
    require(not caveats or (native_install and isinstance(caveats, str) and len(caveats) <= 16384))
    require(not row.get('caveats_rosetta'))
    checksum = row.get('sha256')
    require(isinstance(checksum, str) and (re.fullmatch(r'[0-9a-f]{64}', checksum) or checksum == 'no_check'))
    url = urlsplit(row.get('url', ''))
    require(url.scheme == 'https' and url.hostname and not url.username and not url.password and not url.fragment)
    require(not set(row.get('url_specs') or {}) - {'verified', 'user_agent', 'referer'})
    dependencies = row.get('depends_on') or {}
    require(isinstance(dependencies, dict) and not set(dependencies) - {'macos', 'arch', 'formula', 'cask'})
    for key in ('formula', 'cask'):
        require(all(NAME.fullmatch(v) for v in values(dependencies.get(key, []))))
    if dependencies.get('arch') or dependencies.get('macos'):
        architecture, version = observer.platform()
        architectures = dependencies.get('arch', [])
        if architectures:
            require(isinstance(architectures, list))
            allowed = [v.get('type') if isinstance(v, dict) else v for v in architectures]
            require(all(v in ('arm', 'intel', 'arm64', 'x86_64') for v in allowed))
            require(architecture in allowed or ('arm' if architecture == 'arm64' else 'intel') in allowed,
                    'homebrew_platform_incompatible')
        for operator, expected in dependencies.get('macos', {}).items():
            require(operator in ('>=', '>', '<=', '<', '==', '!='))
            expected = values(expected)
            actual = version_tuple(version)
            comparisons = []
            for minimum in expected:
                minimum = version_tuple(minimum)
                comparisons.append({'>=': actual >= minimum, '>': actual > minimum, '<=': actual <= minimum,
                                    '<': actual < minimum, '==': actual == minimum, '!=': actual != minimum}[operator])
            require(any(comparisons), 'homebrew_platform_incompatible')
    observer.conflicts(row.get('conflicts_with'))


@contract('replacement')
def operation_contract(row, payloads, packages, prefix, observer, operation):
    requirements(row, observer, operation)
    generated = [p for p in payloads if p.get('artifact') == GENERATED_COMPLETIONS]
    if generated:
        require(row['sha256'] != 'no_check' and Path('/usr/bin/sandbox-exec').is_file())
    current = lifecycle(row['artifacts']) if operation == 'reinstall' else {}
    if operation == 'install' and packages:
        # Native Install never acts as receipt adoption or implicit cleanup.
        require(not any(record['present'] for record in packages), CONFLICT)
        for kind, artifact in artifact_rows(row['artifacts']):
            if kind != 'uninstall':
                continue
            for directive in artifact[kind]:
                require(isinstance(directive, dict))
                for entry in values(directive.get('delete', [])):
                    require(not os.path.lexists(path(entry)), CONFLICT)
    privileged = any(kind == 'pkg' or kind == 'keyboard_layout' for kind, _ in artifact_rows(row['artifacts']))
    require(row['sha256'] != 'no_check' or not packages)
    for p in payloads:
        if 'path' in p:
            privileged |= not writable_parent(Path(p['path']))
    if operation == 'reinstall':
        require(not row.get('pinned'), CONFLICT)
        installed, appdir = installed_contract(row, prefix)
        old = lifecycle(installed)
        current_rows = {k + ':' + str(a[k][0]): a for k, a in artifact_rows(row['artifacts'])
                        if k not in ('uninstall', 'zap', 'pkg')}
        for kind, artifact in artifact_rows(installed):
            if kind in ('uninstall', 'zap', 'pkg'):
                continue
            args = artifact[kind]
            if kind == GENERATED_COMPLETIONS:
                counterpart = current_rows.get(kind + ':' + args[0])
                require(counterpart is not None and completion_predicates(args, prefix) ==
                        completion_predicates(counterpart[kind], prefix), CONFLICT)
                continue
            require(isinstance(args, list) and 1 <= len(args) <= 2 and clean(args[0]))
            options = args[1] if len(args) == 2 else {}
            require(isinstance(options, dict))
            counterpart = current_rows.get(kind + ':' + args[0])
            require(counterpart is not None, CONFLICT)
            if artifact.get('target'):
                require(artifact['target'] == counterpart.get('target'), CONFLICT)
            if kind == 'command_wrapper':
                require(not set(options) - {'executable', 'args', 'env'})
            else:
                require(not set(options) - {'target'})
                if options.get('target'):
                    declared = path(options['target']) if options['target'].startswith('/') else path(options['target'], absolute=False)
                    require(declared.name == Path(counterpart['target']).name, CONFLICT)
                    require(not declared.is_absolute() or str(declared) == counterpart['target'], CONFLICT)
        # Compare replacement identities, not versions or lifecycle signatures.
        old_payload = [(k, a[k][0]) for k, a in artifact_rows(installed) if k not in ('uninstall', 'zap', 'pkg')]
        new_payload = [(k, a[k][0]) for k, a in artifact_rows(row['artifacts']) if k not in ('uninstall', 'zap', 'pkg')]
        require(sorted(old_payload) == sorted(new_payload), CONFLICT)
        if generated:
            record_path = Path.home() / 'Library/Application Support/Macseed/Homebrew/contracts' / (row['token'] + '.json')
            record = read_json(record_path) if record_path.exists() else {}
            for predicate in generated:
                target = Path(predicate['path'])
                if target.exists():
                    require(record.get('installed') == row['installed'] and
                            record.get('completion_hashes', {}).get(str(target)) ==
                            hashlib.sha256(target.read_bytes()).hexdigest(), CONFLICT)
        apps = [p for p in payloads if p['kind'] in ('app', 'suite') and 'package' not in p]
        require(not apps or all(str(Path(p['path']).parent) == appdir for p in apps), CONFLICT)
        # Remaining relocated payloads may be foreign replacements; only owned
        # links/package files can coexist with damage without stronger provenance.
        require(all(not os.path.lexists(p['path']) for p in payloads if p['kind'] in ('app', 'suite', 'bundle') and 'package' not in p), CONFLICT)
        orphan = {key: old.get(key, []) for key in ('launchctl', 'login_item')}
        # New current declarations need direct native XPC identity/path evidence;
        # they do not inherit historical declaration authority.
        orphan['xpc_launchctl'] = current.get('launchctl', [])
        privileged |= qualify_cleanup(old, payloads, packages, observer, orphan)
        privileged |= qualify_cleanup(current, payloads, packages, observer, orphan)
    return {'profile': 'authorized_native_lifecycle' if privileged else 'unprivileged',
            'integrity': 'homebrew_checksum' if row['sha256'] != 'no_check' else 'https_source_trust',
            'payloads': payloads, 'cleanup': current if operation == 'reinstall' else {},
            'historical_cleanup': old if operation == 'reinstall' else {},
            'requirements': {k: row.get(k) for k in ('depends_on', 'conflicts_with', 'sha256', 'url', 'url_specs', 'version', 'caveats')},
            'operation': operation}


def classify(row, prefix, observer=None, operation=None, observation_only=False, visited=(), capture=False):
    observer = observer or PublicObserver()
    selected_operation = operation
    try:
        require(isinstance(row, dict) and NAME.fullmatch(row.get('token', '')), 'homebrew_metadata_incompatible')
        installed = row.get('installed')
        require(installed is None or (clean(installed) and '/' not in installed and installed not in ('.', '..')),
                'homebrew_metadata_incompatible')
        require(row['token'] not in visited and len(visited) < 64)
        payloads, packages = predicates(row, prefix, observer)
        saved_path = Path(os.environ.get('BLUEPRINT_GENERATED_DIR', 'config/generated')) / 'homebrew-casks.json'
        if not capture and saved_path.exists():
            captured = read_json(saved_path)
            require(captured.get('contract') == 1 and isinstance(captured.get('casks'), dict), 'homebrew_metadata_incompatible')
            saved = captured['casks'].get(row['token'])
            if saved is not None:
                require(isinstance(saved, dict) and set(saved) == {'state', 'reason', 'required'} and
                        isinstance(saved['required'], list), 'homebrew_metadata_incompatible')
                if packages and not any(record['present'] for record in packages):
                    # Portable source receipt evidence defines fresh-package
                    # postconditions; it never becomes target registration proof.
                    for predicate in saved.get('required', []):
                        if predicate['kind'] != 'receipt':
                            require('target' in predicate)
                            payloads.append({'kind': predicate['kind'], 'path': str(target_from_capture(predicate['target'], prefix)),
                                             'package': packages[0]['id']})
                for predicate in saved.get('required', []):
                    if predicate.get('bundle_id'):
                        require(LABEL.fullmatch(predicate['bundle_id']), 'homebrew_metadata_incompatible')
                        for current in payloads:
                            if current['kind'] == 'app' and Path(current['path']).name == predicate['identity']:
                                current['bundle_id'] = predicate['bundle_id']
                    if predicate.get('members'):
                        for current in payloads:
                            if current['kind'] == 'suite' and Path(current['path']).name == predicate['identity']:
                                current['members'] = predicate['members']
                required = sorted((p['kind'], p['identity']) for p in saved.get('required', []))
                actual = sorted((p['kind'], p.get('id') or Path(p['path']).name) for p in payloads)
                require(bool(required) and required == actual, 'homebrew_metadata_incompatible')
        owned_record = Path.home() / 'Library/Application Support/Macseed/Homebrew/contracts' / (row['token'] + '.json')
        if row.get('installed') and owned_record.exists():
            record = read_json(owned_record)
            if record.get('installed') == row['installed']:
                require(record.get('contract') == 1 and record.get('token') == row['token'], OBSERVATION)
                identities = record.get('bundle_ids', {})
                require(isinstance(identities, dict), OBSERVATION)
                for predicate in payloads:
                    if predicate['kind'] == 'app' and predicate['path'] in identities:
                        identifier = identities[predicate['path']]
                        require(isinstance(identifier, str) and LABEL.fullmatch(identifier), OBSERVATION)
                        require(not predicate.get('bundle_id') or predicate['bundle_id'] == identifier, CONFLICT)
                        predicate['bundle_id'] = identifier
                    if predicate['kind'] == 'suite' and predicate['path'] in record.get('suite_members', {}):
                        predicate['members'] = record['suite_members'][predicate['path']]
        if packages and not row.get('installed'):
            require(not any(record['present'] for record in packages), CONFLICT)
        if packages and not row.get('installed') and not any('path' in p for p in payloads):
            payloads.extend(observer.package_install_payloads(row, [record['id'] for record in packages]))
        missing, _ = observe(payloads, row, prefix)
        registered = bool(row.get('installed'))
        if registered and not missing and not operation:
            value = result('homebrew', 'satisfied', 'compatible')
            value['evidence'] = payloads
            return value
        selected_operation = operation or ('reinstall' if registered else 'install')
        require(selected_operation in ('install', 'reinstall'), 'homebrew_metadata_incompatible')
        if observation_only:
            value = result('homebrew', 'repairable' if registered else 'installable', 'compatible', operation=selected_operation)
            value['evidence'] = payloads
            return value
        require((selected_operation == 'reinstall') == registered, CONFLICT)
        if not registered:
            require(not any('path' in p and os.path.lexists(p['path']) for p in payloads), CONFLICT)
        contract = operation_contract(row, payloads, packages, prefix, observer, selected_operation)
        dependent = []
        for token in values((row.get('depends_on') or {}).get('cask', [])):
            child = classify(observer.cask(token), prefix, observer, visited=(*visited, row['token']))
            if child['state'] not in ('satisfied', 'installable', 'repairable'):
                raise Unsafe(child.get('reason') or UNSUPPORTED, child.get('diagnostic'))
            # Homebrew install does not repair a registered-but-broken dependency.
            require(child['state'] != 'repairable', CONFLICT)
            if child.get('authorization_required'):
                contract['profile'] = 'authorized_native_lifecycle'
            dependent.append({'token': token, 'state': child['state'], 'qualification_id': child.get('qualification_id')})
        contract['dependencies'] = dependent
        value = result('homebrew', 'repairable' if registered else 'installable', 'compatible', operation=selected_operation)
        value.update(evidence=payloads, execution=contract,
                     authorization_required=contract['profile'] == 'authorized_native_lifecycle',
                     qualification_id=hashlib.sha256(json.dumps(contract, sort_keys=True).encode()).hexdigest())
        return value
    except Unsafe as exc:
        state, compatibility = ('incompatible', 'metadata_incompatible') if exc.condition in (
            'homebrew_metadata_incompatible', 'homebrew_platform_incompatible') else (
            'observation_error', 'observation_failure') if exc.condition in (OBSERVATION, 'cask_launchctl_observation_failed') else (
            'unsupported', 'item_unsupported')
        value = result('homebrew', state, compatibility, exc.condition, selected_operation)
        if exc.diagnostic:
            value['diagnostic'] = exc.diagnostic
        return value
    except (OSError, ValueError, TypeError, KeyError, IndexError, AttributeError, subprocess.SubprocessError):
        return result('homebrew', 'observation_error', 'observation_failure', OBSERVATION, selected_operation)


def capture_rows(metadata, prefix, observer=None):
    observer = observer or PublicObserver()
    require(isinstance(metadata.get('casks'), list), OBSERVATION)
    captured = {'contract': 1, 'casks': {}}
    for row in metadata['casks']:
        token = row.get('token', '')
        require(NAME.fullmatch(token) and token not in captured['casks'], OBSERVATION)
        value = classify(row, prefix, observer, observation_only=True, capture=True)
        for predicate in value.get('evidence', []):
            if predicate['kind'] == 'app' and Path(predicate['path']).is_dir():
                target = Path(predicate['path'])
                if bundle_matches(target):
                    predicate['bundle_id'] = plistlib.loads((target / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
            if predicate['kind'] == 'suite' and Path(predicate['path']).is_dir():
                predicate['members'] = [{'name': member.name,
                    'bundle_id': plistlib.loads((member / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']}
                    for member in sorted(Path(predicate['path']).glob('*.app')) if bundle_matches(member)]
        captured['casks'][token] = {'state': value['state'], 'reason': value['reason'],
                                  'required': [{'kind': p['kind'], 'identity': p.get('id') or Path(p['path']).name}
                                               | ({'target': portable_target(Path(p['path']), prefix)} if 'package' in p else {})
                                               | ({'bundle_id': p['bundle_id']} if p.get('bundle_id') else {})
                                               | ({'members': p['members']} if p.get('members') else {})
                                               for p in value.get('evidence', [])]}
    return captured


def save_contract(row, prefix, executed=None):
    value = classify(row, prefix, observation_only=True)
    require(value['state'] == 'satisfied', OBSERVATION)
    executed = executed or row
    require(executed.get('token') == row['token'] and executed.get('version') == row.get('installed'), OBSERVATION)
    from homebrew_lifecycle import private_directory, state_directory
    private_directory(state_directory())
    directory = state_directory() / 'contracts'
    private_directory(directory)
    target = directory / (row['token'] + '.json')
    temporary = target.with_suffix('.tmp')
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        apps = [p for p in value['evidence'] if p['kind'] == 'app' and 'package' not in p]
        with os.fdopen(descriptor, 'w') as stream:
            json.dump({'contract': 1, 'token': row['token'], 'installed': row['installed'],
                       'artifacts': executed['artifacts'], 'appdir': str(Path(apps[0]['path']).parent) if apps else None,
                       'bundle_ids': {p['path']: plistlib.loads((Path(p['path']) / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
                                      for p in value['evidence'] if p['kind'] == 'app'},
                       'completion_hashes': {p['path']: hashlib.sha256(Path(p['path']).read_bytes()).hexdigest()
                                             for p in value['evidence'] if p.get('artifact') == GENERATED_COMPLETIONS},
                       'suite_members': {p['path']: [{'name': member.name,
                           'bundle_id': plistlib.loads((member / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']}
                           for member in sorted(Path(p['path']).glob('*.app'))]
                           for p in value['evidence'] if p['kind'] == 'suite'}}, stream)
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    try:
        metadata = json.load(sys.stdin)
        if sys.argv[2:] == ['--capture']:
            print(json.dumps(capture_rows(metadata, Path(sys.argv[1])), sort_keys=True))
            return 0
        require(isinstance(metadata.get('casks'), list) and len(metadata['casks']) == 1, 'homebrew_metadata_incompatible')
        row, prefix = metadata['casks'][0], Path(sys.argv[1])
        mode = sys.argv[2] if len(sys.argv) > 2 else '--classify'
        if mode == '--record':
            snapshot = Path(os.environ['MACSEED_ITEM_STATE_DIR']) / 'homebrew-applied-metadata.json'
            executed = read_json(snapshot)['casks'][0]
            save_contract(row, prefix, executed)
            return 0
        value = classify(row, prefix, operation=sys.argv[3] if len(sys.argv) > 3 else None,
                         observation_only=mode == '--observe')
        print(json.dumps(value, sort_keys=True))
        return (0 if value['state'] == 'satisfied' else 1 if value['state'] in ('installable', 'repairable') else 2) if mode == '--observe' else 0
    except (Unsafe, OSError, ValueError, KeyError, IndexError):
        print(json.dumps(result('homebrew', 'incompatible', 'metadata_incompatible', 'homebrew_metadata_incompatible')))
        return 2


if __name__ == '__main__':
    sys.exit(main())
