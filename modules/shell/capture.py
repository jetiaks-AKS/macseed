"""Functions Capture adapter. Observation/codec/launch policy remain domain-owned."""
from collections import Counter
import importlib.util
import json
import os
from pathlib import Path
import plistlib
from xml.parsers.expat import ExpatError

spec = importlib.util.spec_from_file_location('shell_observe', Path(__file__).with_name('observe.py'))
observe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observe)
state = observe.state
client = observe.client


def parser(root):
    """Read the trusted launch configuration, never derive trust from build.json.

    Desktop and the fixed development app use the existing trusted CoreRuntime
    descriptor. Stage 17 must seal this descriptor after final nested signing,
    just like the Core/Python location.
    """
    client.Parser.require_available()
    bundle = Path(os.environ.get('MACSEED_DESKTOP_BUNDLE', root / 'desktop/Macseed/build/Debug/Macseed.app'))
    with client._file(bundle / 'Contents/Resources/CoreRuntime.plist', 16384) as (_, raw, _):
        try:
            value = plistlib.loads(raw)
            if (type(value) is not dict or type(value.get('Version')) is not int or value['Version'] != 1
                    or value.get('Mode') != 'development' or value.get('CoreRoot') != str(root)):
                raise ValueError()
            anchor = value.get('ShellParserManifestSHA256')
        except (ValueError, TypeError, ExpatError):
            raise client.Invalid('helper_untrusted') from None
    return client.Parser(bundle=bundle, manifest_sha256=anchor)


class Observation:
    def __init__(self, root):
        self.snapshot = None
        self.binding = None
        self._source_paths = ()
        self.public = dict(status='unavailable', codes=[], restore_supported=True)
        try:
            helper = parser(root)
            result = observe.observe(os.environ['HOME'], helper, aliases=True, independent=True)
            self.public.update(status='observed' if result.snapshot._value['items'] or not result.codes else 'unsupported',
                               codes=list(result.codes), uncertainties=list(result.uncertainties))
            loaded = {row['source'] for row in result._loads}
            exclusions = {}
            unresolved = False
            mentions = Counter(name for f in result._files.values() for name in f['alias_names'] + f['names'])
            for record in result._files.values():
                unresolved |= record.get('unresolved_aliases', False)
                for name, reason in record.get('excluded_aliases', []):
                    if (record['source']['id'] in loaded and record['status'] == 'partial' and
                            mentions[name] == 1):
                        exclusions[name] = reason
                    else:
                        unresolved = True
            if exclusions and len(exclusions) <= observe.base.MAX_ITEMS:
                self.public['excluded_aliases'] = exclusions
            if unresolved or len(exclusions) > observe.base.MAX_ITEMS:
                self.public['codes'] = sorted(set(result.codes) | {'alias_scope_unresolved'})
            # A bounded declaration recipe is distinct from a startup snapshot.
            # Rejected source relationships stay explicit outside its scope.
            try:
                state.declaration_order(result.snapshot)  # Must have a portable Restore order.
            except state.Invalid:
                self.public.update(status='unsupported', codes=sorted(set(self.public['codes']) | {'ambiguous_function'}))
                return
            raw, payloads = state.encode(result.snapshot)
            evidence = dict(parser=helper._manifest_sha256, snapshot=state.digest(raw),
                            payloads={k: state.digest(v) for k, v in payloads.items()},
                            files={p: dict(status=f['status'], stamp=f['stamp'],
                                           sha256=state.digest(f['raw']) if f['raw'] is not None else None)
                                   for p, f in result._files.items()},
                            loads=result._loads, uncertainties=result.uncertainties)
            self.binding = state.digest(json.dumps(evidence, sort_keys=True, separators=(',', ':')).encode())
            self.snapshot = result.snapshot
            self._source_paths = tuple(result._files)
        except (client.Invalid, observe.Invalid) as exc:
            if exc.code in ('cancelled', 'process_cleanup_failed'):
                raise
            self.public['codes'] = [exc.code]

    def __repr__(self):
        return '<ShellCaptureObservation private>'

    def entries(self):
        if self.snapshot is None:
            return []
        return [dict(item_id=row['id'], label=row['key'], _source=row['id'])
                for row in self.snapshot._value['items']]

    def selected(self, ids, scripts=()):
        return state.encode(state.with_scripts(state.select(self.snapshot, ids), scripts))

    def validate_script_paths(self, ids, paths):
        """Apply v5 source-file exclusions using actual selected typed aliases."""
        selected = state.select(self.snapshot, ids)
        context = dict(roots=list(self._source_paths),
                       aliases=[observe.base.typed_declaration(state.content(selected, row).decode('utf-8'))[0]
                                for row in selected._value['items'] if row['kind'] == 'alias'],
                       layout=[dict(path=p) for p in self._source_paths])
        if any(not state.legacy().script_path(context, path, typed=True) for path in paths):
            raise state.Invalid('content_invalid')


def function_id(value):
    return isinstance(value, str) and value.startswith('shell-function:')
