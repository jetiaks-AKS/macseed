"""Core-owned ordinary Restore selection; only narrows private Blueprint state."""
import hashlib
import re

import bundle

LABELS = {
    'homebrew-packages': 'Homebrew Packages', 'homebrew-casks': 'Homebrew Applications',
    'app-store': 'App Store Applications', 'vscode-extensions': 'VS Code Extensions',
    'workspace-folders': 'Workspace Folders', 'git-repositories': 'Git Repositories',
    'vscode-workspaces': 'VS Code Workspaces',
    'git-configuration': 'Git Configuration', 'vscode-settings': 'VS Code Settings',
    'shell-zsh': 'Shell Configuration', 'ssh-configuration': 'SSH Configuration',
    'macos-finder': 'Finder', 'macos-dock': 'Dock', 'macos-windows': 'Windows',
    'macos-keyboard': 'Keyboard', 'macos-trackpad': 'Trackpad', 'macos-screenshots': 'Screenshots',
}


class InvalidSelection(Exception):
    pass


def identity(domain, source):
    if domain == 'vscode-workspaces':
        return source
    return 'restore:' + hashlib.sha256((domain + '\0' + source).encode()).hexdigest()


def label(source, domain=None):
    # Values/remotes are never candidates. Unsafe identifiers get a neutral label.
    if domain in ('homebrew-packages', 'homebrew-casks'):
        token = r'[A-Za-z0-9][A-Za-z0-9+_.@-]*'
        pattern = token + (rf'(?:/{token}/{token})?' if domain == 'homebrew-packages' else '')
        suffix = r'\.rb$' if domain == 'homebrew-packages' else r'\.(rb|json|sh|bash|zsh|dmg|pkg|zip)$'
        return source if (len(source) <= 160 and re.fullmatch(pattern, source) and
                          not re.search(suffix, source, re.I)) else 'Private item'
    return source if re.fullmatch(r'[\w . /-]{1,160}', source, re.UNICODE) and not source.startswith('/') else 'Private item'


def inventory(files):
    sections, categories = bundle.parse_blueprint(files['blueprint.conf'])
    folders = {}
    if sections['workspace-folders']:
        folders = dict(line.split('|') for line in files['generated/workspace/folders.conf'].decode().splitlines() if line)
    app_names = dict(line.split('|', 1) for line in files.get('generated/appstore.conf', b'').decode().splitlines() if '|' in line)
    repository_names = {}
    if 'generated/workspace/topology.json' in files:
        repository_names = {item: row['name'] for item, row in bundle.workspace_contract().repository_records(
            files['generated/workspace/repositories.conf']).items()}
    workspace_names = {}
    if 'generated/workspace/vscode-workspaces.json' in files:
        contract = bundle.workspace_contract()
        workspace_names = {row['item_id']: contract.workspace_label(row['path'])
                           for row in contract.objects(files[contract.VSCODE])['items']}
    rows = []
    sources = {}
    for domain in (*bundle.SELECTABLE_ITEMS, *bundle.CATEGORIES):
        items = sections.get(domain, [])
        if domain == 'workspace-folders':
            items = [value for value in items if folders.get(value) == 'workspace']
        sources[domain] = {identity(domain, source): source for source in items}
        if len(sources[domain]) != len(items):
            raise bundle.Invalid('ambiguous Restore selection inventory')
        available = bool(items) if domain in bundle.SELECTABLE_ITEMS else categories[domain]
        rows.append({'domain': domain, 'label': LABELS[domain],
                     'selection_mode': 'items' if domain in bundle.SELECTABLE_ITEMS else 'category',
                     'availability': 'available' if available else 'unavailable',
                     'capture_selected': bool(categories.get(domain, False) or sections.get(domain, [])),
                     'source_present': 'generated/' + (bundle.SELECTABLE_ITEMS.get(domain) or bundle.CATEGORIES[domain]) in files,
                     'reason': None if available else 'no_selectable_content',
                     'items': [{'item_id': key, 'label': label(app_names.get(value, value) if domain == 'app-store' else
                                repository_names.get(value, value) if domain == 'git-repositories' else
                                workspace_names.get(value, value) if domain == 'vscode-workspaces' else value, domain)} for key, value in sources[domain].items()]})
    return {'groups': [{'id': group, 'domains': list(domains)} for group, domains in bundle.GROUPS.items()],
            'inventory': rows}, sources


def staged_files(stage):
    return {str(path.relative_to(stage)): bundle.checked_file(path) for path in stage.rglob('*') if path.is_file()}


def canonical(stage):
    sections, categories = bundle.parse_blueprint(bundle.checked_file(stage / 'blueprint.conf'))
    return {'categories': sorted(domain for domain in bundle.CATEGORIES if categories[domain]),
            'items': {domain: sorted(identity(domain, value) for value in values)
                      for domain, values in sorted(sections.items()) if domain in bundle.SELECTABLE_ITEMS and values}}


def narrow(stage, selection, disabled_groups):
    if selection is None:
        return
    if (not isinstance(selection, dict) or set(selection) != {'categories', 'items'} or
            not isinstance(selection['categories'], list) or not isinstance(selection['items'], dict)):
        raise InvalidSelection()
    whole, subsets = selection['categories'], selection['items']
    if (not all(isinstance(value, str) for value in whole) or len(set(whole)) != len(whole) or
            set(whole) & set(subsets)):
        raise InvalidSelection()
    projection, sources = inventory(staged_files(stage))
    rows = {row['domain']: row for row in projection['inventory']}
    excluded = {domain for group in disabled_groups for domain in bundle.GROUPS[group]}
    chosen = set(whole) | set(subsets)
    if any(domain not in rows or domain in excluded or rows[domain]['availability'] != 'available' for domain in chosen):
        raise InvalidSelection()
    selected_items = {}
    for domain in chosen:
        if domain in subsets:
            values = subsets[domain]
            if (rows[domain]['selection_mode'] != 'items' or not isinstance(values, list) or not values or
                    not all(isinstance(value, str) for value in values) or len(set(values)) != len(values) or
                    not set(values).issubset(sources[domain])):
                raise InvalidSelection()
            selected_items[domain] = {sources[domain][value] for value in values}
        elif domain in bundle.SELECTABLE_ITEMS:
            selected_items[domain] = set(sources[domain].values())
    sections, categories = bundle.parse_blueprint(bundle.checked_file(stage / 'blueprint.conf'))
    flags = {domain: categories[domain] and domain in chosen for domain in bundle.CATEGORY_FLAGS}
    raw = '[categories]\n' + ''.join(f'{domain}="{str(value).lower()}"\n' for domain, value in sorted(flags.items()))
    for domain in bundle.SELECTABLE_ITEMS:
        if domain in bundle.EXTENSION_ITEMS and not selected_items.get(domain):
            continue
        raw += '\n[' + domain + ']\n' + ''.join(value + '\n' for value in sections.get(domain, []) if value in selected_items.get(domain, set()))
    bundle.parse_blueprint(raw.encode())
    temporary = stage / 'blueprint.selection'
    bundle.write_file(temporary, raw.encode())
    temporary.replace(stage / 'blueprint.conf')


def correlate(records, stage):
    sections, _ = bundle.parse_blueprint(bundle.checked_file(stage / 'blueprint.conf'))
    for row in records:
        domain = row['domain']
        if domain not in bundle.SELECTABLE_ITEMS:
            continue
        source = row['item_id']
        if domain == 'git-repositories':
            if not source.isdecimal() or not 1 <= int(source) <= len(sections[domain]):
                continue
            source = sections[domain][int(source) - 1]
        if source in sections[domain]:
            row['selection_item_id'] = identity(domain, source)
