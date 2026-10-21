"""Bounded application identity correlation; never installation or provider ownership.

An Apple catalog ID binding and a qualified Cask payload identify an application.
They do not make its distributions interchangeable or authorize replacing a target.
"""
import json
from itertools import islice
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time

IDENTIFIER = re.compile(r'[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+')
TOKEN = re.compile(r'[A-Za-z0-9][A-Za-z0-9+_.@-]*')
MAX_LOOKUP = 50
CATALOG_TTL = 30 * 24 * 60 * 60
CATALOG_LIMIT = 2048


def catalog_directory(create=False):
    """Owner-private catalog evidence, separate from installed-provider state."""
    root = Path.home().resolve() / 'Library/Application Support/Macseed/ApplicationIdentities'
    if create:
        sys.path.insert(0, str(Path(__file__).resolve().parent / 'adapters'))
        from homebrew_lifecycle import private_directory
        private_directory(root)
    for part in (root, *root.parents):
        if part == Path.home().resolve():
            break
        info = part.lstat()
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
            raise ValueError('unsafe identity directory')
        if part == root and (info.st_uid != os.getuid() or info.st_mode & 0o077):
            raise ValueError('unsafe identity directory')
    return root


def cached_binding(app_id):
    try:
        fd = os.open(catalog_directory() / (app_id + '.json'),
                     os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd) as stream:
            info = os.fstat(stream.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_mode & 0o077 or info.st_nlink != 1 or info.st_size > 4096):
                return None
            value = json.load(stream)
        if (not isinstance(value, dict) or set(value) != {'contract', 'app_id', 'bundle_id', 'confirmed'}
                or type(value['contract']) is not int or value['contract'] != 1 or value['app_id'] != app_id
                or type(value['confirmed']) not in (int, float)
                or not 0 <= time.time() - value['confirmed'] < CATALOG_TTL
                or not isinstance(value['bundle_id'], str) or len(value['bundle_id']) > 255
                or not IDENTIFIER.fullmatch(value['bundle_id'])):
            return None
        return value['bundle_id']
    except (OSError, ValueError, TypeError, RecursionError):
        return None


def save_binding(app_id, bundle_id):
    """Only successful HTTPS bindings are persisted; failure never erases evidence."""
    try:
        root = catalog_directory(create=True)
        target = root / (app_id + '.json')
        if len(list(islice(root.iterdir(), CATALOG_LIMIT))) >= CATALOG_LIMIT and not target.exists():
            return
        fd, name = tempfile.mkstemp(prefix='confirming-', dir=root)
        try:
            with os.fdopen(fd, 'w') as stream:
                json.dump({'contract': 1, 'app_id': app_id, 'bundle_id': bundle_id,
                           'confirmed': time.time()}, stream)
            os.replace(name, target)
        finally:
            Path(name).unlink(missing_ok=True)
    except (OSError, ValueError):
        pass  # Persistence is optional; a failed write is not identity evidence.


def numeric_id(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9]{1,20}', value) and int(value) > 0


def catalog_bindings(data, ids):
    """Reject ambiguous, non-Mac, unsolicited or malformed catalog responses."""
    if (not isinstance(data, dict) or type(data.get('resultCount')) is not int or
            not isinstance(data.get('results'), list) or
            data['resultCount'] != len(data['results']) or len(data['results']) > len(ids)):
        return {}
    requested = {str(int(value)): value for value in ids}
    if len(requested) != len(ids):
        return {}
    result = {}
    seen = set()
    for row in data['results']:
        if (not isinstance(row, dict) or type(row.get('trackId')) is not int or
                str(row['trackId']) not in requested):
            return {}
        app_id = requested[str(row['trackId'])]
        if app_id in seen:
            return {}
        seen.add(app_id)
        # A universal/iOS listing or unusable identity is unresolved only for that
        # record; it must not discard independent, valid Mac catalog bindings.
        if (row.get('kind') != 'mac-software' or not isinstance(row.get('bundleId'), str) or
                not IDENTIFIER.fullmatch(row['bundleId'])):
            continue
        result[app_id] = row['bundleId']
    return result


def fetch_catalog(ids):
    """One HTTPS ID-only request, no redirects, credentials, search or retries.

    Failure is absence of correlation evidence, never an absent application.
    curl's own configuration is disabled; certificate verification stays enabled.
    """
    if not ids or len(ids) > MAX_LOOKUP or not all(numeric_id(value) for value in ids):
        return {}
    try:
        observed = subprocess.run(
            ['/usr/bin/curl', '--disable', '--silent', '--fail', '--proto', '=https',
             '--connect-timeout', '2', '--max-time', '4', '--max-filesize', '1048576',
             '--get', '--data-urlencode', 'id=' + ','.join(ids),
             '--data-urlencode', 'entity=macSoftware', 'https://itunes.apple.com/lookup'],
            stdin=subprocess.DEVNULL, capture_output=True, timeout=5, check=False)
        if observed.returncode or len(observed.stdout) > 1048576:
            return {}
        try:
            data = json.loads(observed.stdout)
        except RecursionError:
            return {}
        return catalog_bindings(data, ids)
    except (OSError, ValueError, UnicodeError, subprocess.SubprocessError):
        return {}


def lookup_catalog(ids):
    """Reuse positive bindings across Core processes; never cache installation state.

    Valid evidence lasts 30 days without sliding renewal. Only unresolved IDs go
    to Apple. Expired/unsafe/absent records need a fresh successful lookup.
    """
    if (not ids or len(ids) > MAX_LOOKUP or not all(numeric_id(value) for value in ids)
            or len({int(value) for value in ids}) != len(ids)):
        return {}
    result = {app_id: binding for app_id in ids if (binding := cached_binding(app_id)) is not None}
    unresolved = [app_id for app_id in ids if app_id not in result]
    if unresolved:
        observed = fetch_catalog(unresolved)
        for app_id, binding in observed.items():
            save_binding(app_id, binding)
        result.update(observed)
    return result


def cask_bindings(capabilities, selected):
    """Use a single qualified, observed app payload, not a label or token guess."""
    result = {}
    for token, row in capabilities.get('casks', {}).items():
        if token not in selected or row.get('state') != 'satisfied' or row.get('reason') is not None:
            continue
        applications = [p for p in row.get('required', []) if p.get('kind') in ('app', 'suite', 'bundle')]
        if len(applications) != 1 or applications[0]['kind'] != 'app':
            continue
        identifier = applications[0].get('bundle_id')
        if isinstance(identifier, str) and IDENTIFIER.fullmatch(identifier):
            result[token] = identifier
    return result


def installed_capabilities(tokens):
    """Legacy fallback: registered local app Casks through the existing observer.

    No catalog fetch by token, installer download, scan of arbitrary apps or native
    package inspection. Missing/broken/protected targets supply no identity.
    """
    if not tokens or len(tokens) > 2048 or not all(TOKEN.fullmatch(t) for t in tokens):
        return {'contract': 1, 'casks': {}}
    try:
        environment = dict(os.environ, HOMEBREW_NO_AUTO_UPDATE='1', HOMEBREW_NO_SUDO='1')
        def read(arguments):
            result = subprocess.run(arguments, env=environment, stdin=subprocess.DEVNULL,
                                    capture_output=True, timeout=4, check=False)
            if result.returncode or len(result.stdout) > 4 * 1024 * 1024:
                raise ValueError()
            return result.stdout
        try:
            metadata = json.loads(read(['brew', 'info', '--json=v2', '--installed', '--cask']))
        except RecursionError:
            return {'contract': 1, 'casks': {}}
        if not isinstance(metadata, dict) or not isinstance(metadata.get('casks'), list):
            return {'contract': 1, 'casks': {}}
        prefix = Path(read(['brew', '--prefix']).decode().strip())
        if not prefix.is_absolute():
            return {'contract': 1, 'casks': {}}
        rows = [r for r in metadata['casks'] if isinstance(r, dict) and r.get('token') in tokens]
        # Restrict the legacy probe to app artifacts and their passive metadata.
        allowed = {'app', 'binary', 'uninstall', 'zap'}
        rows = [r for r in rows if r.get('installed') and isinstance(r.get('artifacts'), list)
                and all(isinstance(a, dict) and set(a) - {'target'} <= allowed for a in r['artifacts'])
                and sum('app' in a for a in r['artifacts']) == 1]
        sys.path.insert(0, str(Path(__file__).resolve().parent / 'adapters'))
        from homebrew_cask import capture_rows, Unsafe
        try:
            return capture_rows({'casks': rows}, prefix)
        except Unsafe:
            return {'contract': 1, 'casks': {}}
    except (OSError, ValueError, TypeError, KeyError, UnicodeError, subprocess.SubprocessError):
        return {'contract': 1, 'casks': {}}


def overlaps(casks, app_ids, capabilities, allow_installed=False):
    """Return unambiguous ID→Cask pairs plus portable evidence used for legacy IDs."""
    if not casks or not app_ids or len(app_ids) > MAX_LOOKUP or not all(numeric_id(i) for i in app_ids):
        return {}, {}
    captured = cask_bindings(capabilities, casks)
    live = {'contract': 1, 'casks': {}}
    if allow_installed:
        # Existing evidence, including unsupported evidence, is never replaced.
        missing = set(casks) - set(capabilities.get('casks', {}))
        if missing:
            live = installed_capabilities(missing)
    bindings = captured | cask_bindings(live, casks)
    if not bindings:
        return {}, {}
    store = lookup_catalog(app_ids)
    pairs = {}
    for app_id, identifier in store.items():
        candidates = [token for token, value in bindings.items() if value == identifier]
        if len(candidates) == 1 and list(store.values()).count(identifier) == 1:
            pairs[app_id] = candidates[0]
    return pairs, {token: live['casks'][token] for token in pairs.values() if token in live['casks']}
