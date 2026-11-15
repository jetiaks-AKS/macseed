#!/usr/bin/env python3
"""Read-only Protocol V1 Compare through production readers on disposable Macs."""
import hashlib
import copy
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'modules/ssh'))
import ssh_merge
import host_presentation
shell_spec = importlib.util.spec_from_file_location('shell_aliases', ROOT / 'modules/shell/aliases.py')
shell_aliases = importlib.util.module_from_spec(shell_spec)
shell_spec.loader.exec_module(shell_aliases)


class ShellRecoveryTests(unittest.TestCase):
    def test_v5_source_copy_keeps_os_provenance_and_other_metadata(self):
        c = self.contract
        raw = b'eval "$(echo not-executed)"\n# unrelated bytes\n'
        suffix = b"alias fixture_a='echo A'\nalias fixture_b='echo B'\n"
        (self.source / '.zshrc').write_bytes(raw + suffix)
        value = c.authorize_capture(c.capture(str(self.source)), str(self.source), [], policy=c.FILE_POLICY)
        target = self.home / '.zshrc'; target.write_bytes(raw); target.chmod(0o640); os.chflags(target, 0x40)
        self.set_xattr(target, 'com.apple.TextEncoding', b'utf-8;134217984')
        before = target.stat()
        attributes = c.sources.attributes
        # Model both source and new-inode provenance: the runner's process
        # origin need not create it. Only reads are simulated; every native
        # copy/write/exchange/document-ID operation is real.
        def foreign_origin(fd):
            result = attributes(fd)
            result[b'com.apple.provenance'] = (b'opaque-source-origin'
                if os.fstat(fd).st_ino == before.st_ino else b'opaque-created-origin')
            return result
        with patch.object(c.sources, 'attributes', side_effect=foreign_origin):
            with c.sources.parent(str(self.home), '.zshrc') as (fd, name, _):
                _, info, metadata = c.sources.mutable_file(fd, name, tracked=True)
                document = c.sources.document_id(fd, name, info)
                # Historical metadata equality remains strict.
                with self.assertRaisesRegex(ValueError, 'metadata_copy_mismatch'):
                    c.sources.write_file(fd, 'legacy-copy', raw, source=(fd, name, info, metadata))
            self.assertTrue(c.publish(value, str(self.home), c.evidence(value, str(self.home))))
            self.assertEqual([state for _, state, _ in c.comparison(value, str(self.home))['rows']], ['matching'] * 2)
            with c.sources.parent(str(self.home), '.zshrc') as (fd, name, _):
                actual, after, copied = c.sources.mutable_file(fd, name, tracked=True)
                self.assertEqual(c.sources.document_id(fd, name, after), document)
            self.assertEqual(actual, raw + suffix)
            self.assertEqual(c.base.stamp(after)[2:6], c.base.stamp(before)[2:6])
            self.assertEqual({k: v for k, v in copied.items() if k != b'com.apple.provenance'},
                             {k: v for k, v in metadata.items() if k != b'com.apple.provenance'})
            predecessor, = self.home.glob('.macseed-shell-predecessor-*')
            with c.sources.parent(str(self.home), predecessor.name + '/swap') as (fd, name, _):
                old_raw, old_info, old_attrs = c.sources.mutable_file(fd, name, tracked=True)
                self.assertEqual((old_raw, old_info.st_ino, old_attrs), (raw, before.st_ino, metadata))
            stamp = c.base.stamp(after)
            self.assertFalse(c.publish(value, str(self.home)))
            self.assertEqual(c.base.stamp(target.stat()), stamp)

    def test_v5_source_copy_without_os_provenance(self):
        c = self.contract
        attributes = c.sources.attributes
        def no_origin(fd):
            result = attributes(fd)
            result.pop(b'com.apple.provenance', None)
            return result
        # The same real safe-save/no-op contract also applies when neither
        # inode has OS provenance. Never set or clear that xattr on disk.
        with patch.object(c.sources, 'attributes', side_effect=no_origin):
            self.test_v5_dynamic_tracked_source_safe_save_and_noop()

    def test_v5_source_copy_failures_keep_pending_and_safe_diagnostics(self):
        c = self.contract
        raw = b'eval "$(echo ignored)"\n'
        (self.source / '.zshrc').write_bytes(raw + b"alias fixture='echo A'\n")
        value = c.authorize_capture(c.capture(str(self.source)), str(self.source), [], policy=c.FILE_POLICY)
        for failure in ('copy-failed', 'lost-attribute', 'changed-provenance', 'quarantine-change', 'lost-quarantine', 'source-changed', 'late-staging-change', 'after-publication'):
            with self.subTest(failure=failure):
                home = self.root / failure; home.mkdir(mode=0o700)
                target = home / '.zshrc'; target.write_bytes(raw); target.chmod(0o600); os.chflags(target, 0x40)
                self.set_xattr(target, 'com.apple.TextEncoding', b'utf-8;134217984')
                if failure in ('quarantine-change', 'lost-quarantine'):
                    self.set_xattr(target, 'com.apple.quarantine', b'0083;12345678;Fixture;')
                original_ino = target.stat().st_ino
                attributes, native, rename = c.sources.attributes, c.sources.native, c.sources.rename
                copied, exchanged, flushed = set(), [], set()
                fsync = os.fsync
                def sync(fd):
                    result = fsync(fd); flushed.add(os.fstat(fd).st_ino)
                    return result
                def observed(fd):
                    attrs = attributes(fd)
                    ino = os.fstat(fd).st_ino
                    if ino in copied and failure == 'lost-attribute': attrs.pop(b'com.apple.TextEncoding', None)
                    if ino in copied and failure == 'changed-provenance': attrs[b'com.apple.provenance'] = b'unexpected'
                    # Some macOS hosts copy quarantine exactly. Inject the
                    # failure explicitly rather than relying on an OS change.
                    if ino in copied and failure == 'quarantine-change': attrs[b'com.apple.quarantine'] = b'0083;12345678;Changed;'
                    if ino in copied and failure == 'lost-quarantine': attrs.pop(b'com.apple.quarantine', None)
                    if ino in flushed and failure == 'late-staging-change': attrs.pop(b'com.apple.TextEncoding', None)
                    if exchanged and failure == 'after-publication' and ino != original_ino: attrs.pop(b'com.apple.TextEncoding', None)
                    return attrs
                def library():
                    lib = native(); copy_file = lib.fcopyfile
                    def copy(a, b, state, flags):
                        if failure == 'copy-failed': return -1
                        status = copy_file(a, b, state, flags); copied.add(os.fstat(b).st_ino)
                        if failure == 'source-changed': target.write_bytes(raw + b'# external edit\n')
                        return status
                    lib.fcopyfile = copy
                    return lib
                def exchange(*args):
                    result = rename(*args)
                    if args[1] == 'swap': exchanged.append(True)
                    return result
                with patch.object(c.sources, 'native', side_effect=library), patch.object(c.sources, 'attributes', side_effect=observed), patch.object(c.sources, 'rename', side_effect=exchange), patch.object(os, 'fsync', side_effect=sync):
                    with self.assertRaises(c.base.PublicationUncertain) as raised:
                        c.publish(value, str(home))
                pending, = home.glob('.macseed-shell-pending-*')
                self.assertEqual((pending / 'observed').read_bytes(), raw)
                self.assertEqual(target.stat().st_flags, 0x40)
                diagnostic = shell_aliases.failure_diagnostic(raised.exception)
                self.assertNotIn(str(home), diagnostic)
                self.assertEqual(diagnostic, 'shell_verification_publication_uncertain' if exchanged else
                    'shell_staging_' + ('metadata_copy_failed' if failure == 'copy-failed' else
                    'target_changed' if failure in ('source-changed', 'late-staging-change') else 'metadata_copy_mismatch'))
                if not exchanged:
                    self.assertEqual(target.read_bytes(), raw + (b'# external edit\n' if failure == 'source-changed' else b''))
                    self.assertEqual(target.stat().st_ino, original_ino)
                self.assertEqual(c.plan(value, str(home))['reason'], 'publication_uncertain')
                self.assertFalse(c.plan(value, str(home))['writes'])
                self.assertEqual(c.comparison(value, str(home))['rows'][0][1], 'unverified')
                with self.assertRaises(ValueError): c.publish(value, str(home))
        # Arbitrary exception messages and paths never become diagnostics.
        self.assertEqual(shell_aliases.failure_diagnostic(OSError('private contents /private/path')), 'shell_preflight_observation_failed')

    def test_v5_dynamic_tracked_source_safe_save_and_noop(self):
        c = self.contract
        raw = b'eval "$(touch "$HOME/startup-must-not-run")"\nhelper() { :; }\n# retained\n'
        suffix = b"alias fixture='echo A'\n"
        (self.source / '.zshrc').write_bytes(raw + suffix)
        value = c.authorize_capture(c.capture(str(self.source)), str(self.source), [], policy=c.FILE_POLICY)
        target = self.home / '.zshrc'; target.write_bytes(raw); target.chmod(0o640)
        subprocess.run(['/usr/bin/xattr', '-w', 'com.apple.TextEncoding', 'utf-8;134217984', str(target)], check=True)
        os.chflags(target, 0x40)
        with c.sources.parent(str(self.home), '.zshrc') as (fd, name, _):
            original, before, attributes = c.sources.mutable_file(fd, name, tracked=True)
            document = c.sources.document_id(fd, name, before)
            with self.assertRaisesRegex(ValueError, 'unsupported_metadata'):
                c.sources.mutable_file(fd, name)  # No global flags-policy relaxation.
        self.assertFalse(value['layout'][0]['closed'])
        self.assertFalse(c.sources.observe(str(self.home))['writable'])
        self.assertEqual(c.observation(value, str(self.home))['documents'], {'.zshrc': document})
        with patch('subprocess.Popen', side_effect=AssertionError('never execute startup')):
            self.assertEqual(c.plan(value, str(self.home))['rows'][0][1:], ('missing', 'add'))
            self.assertTrue(c.publish(value, str(self.home), c.evidence(value, str(self.home))))
            self.assertEqual(c.comparison(value, str(self.home))['rows'][0][1], 'matching')
            stamp = c.base.stamp(target.stat())
            self.assertFalse(c.publish(value, str(self.home)))
            self.assertEqual(c.base.stamp(target.stat()), stamp)
        with c.sources.parent(str(self.home), '.zshrc') as (fd, name, _):
            result, after, actual = c.sources.mutable_file(fd, name, tracked=True)
            self.assertEqual(c.sources.document_id(fd, name, after), document)
        self.assertEqual(result, original + suffix)
        self.assertEqual(attributes, actual)
        self.assertEqual((after.st_uid, after.st_gid, after.st_mode, after.st_flags),
                         (before.st_uid, before.st_gid, before.st_mode, before.st_flags))
        self.assertNotEqual(after.st_ino, before.st_ino, 'Safe-save preserves document ID, not the replaced inode')
        predecessor, = self.home.glob('.macseed-shell-predecessor-*')
        self.assertEqual((predecessor / 'swap').read_bytes(), original)
        self.assertEqual((predecessor / 'swap').stat().st_ino, before.st_ino)
        self.assertEqual((predecessor / 'swap').stat().st_flags, 0x40)
        self.assertFalse((self.home / 'startup-must-not-run').exists())

    def test_v5_dynamic_source_append_rejects_ambiguous_context(self):
        c = self.contract
        dynamic = b'eval "$(echo ignored)"\n'
        definition = b"alias fixture='echo A'\n"
        (self.source / '.zshrc').write_bytes(dynamic + definition)
        value = c.authorize_capture(c.capture(str(self.source)), str(self.source), [], policy=c.FILE_POLICY)
        target = self.home / '.zshrc'
        for raw in [dynamic + b'return\n', dynamic + b'echo unfinished &&\n',
                    dynamic + b'echo unfinished \\', b'eval "$(unterminated\n',
                    dynamic + definition * 2, dynamic + b"alias fixture='echo different'\n",
                    dynamic + b'fixture() { :; }\n', dynamic + b'unalias fixture\n',
                    dynamic + b'if true; then ' + definition + b'fi\n',
                    dynamic + b'alias "$UNKNOWN_DEFINITION"\n',
                    dynamic + b'source "$HOME/missing-source"\n']:
            with self.subTest(raw=raw):
                target.write_bytes(raw); target.chmod(0o600); os.chflags(target, 0x40)
                before = (raw, c.base.stamp(target.stat()))
                self.assertFalse(c.plan(value, str(self.home))['writes'])
                with self.assertRaises(ValueError): c.publish(value, str(self.home))
                self.assertEqual((target.read_bytes(), c.base.stamp(target.stat())), before)
        target.write_bytes(dynamic)
        for flag in (0, 0x40):
            os.chflags(target, flag)
            self.assertEqual(set(c.plan(value, str(self.home))['writes']), {'.zshrc'})
        legacy = c.authorize_capture(c.capture(str(self.source)), str(self.source), [], policy=c.OPAQUE_POLICY)
        self.assertEqual(c.plan(legacy, str(self.home))['reason'], 'source_prerequisite')
        with patch.object(c.sources, 'swap_supported', side_effect=c.base.Invalid('publication_unavailable')):
            self.assertFalse(c.plan(value, str(self.home))['writes'])
        with patch.object(c.sources, 'document_id', side_effect=c.base.Invalid('document_identity_unavailable')):
            self.assertFalse(c.plan(value, str(self.home))['writes'])
        with c.sources.parent(str(self.home), '.zshrc') as (fd, name, _):
            info = target.stat()
            for length, identifier in ((4, 42), (8, 0)):
                def invalid_attribute(_fd, _attributes, output, _size, _options):
                    output._obj[0], output._obj[1] = length, identifier
                    return 0
                with patch.object(c.sources, 'native') as native:
                    native.return_value.fgetattrlist.side_effect = invalid_attribute
                    with self.assertRaisesRegex(ValueError, 'document_identity_unavailable'):
                        c.sources.document_id(fd, name, info)
        expected = c.evidence(value, str(self.home))
        read_document = c.sources.document_id
        with patch.object(c.sources, 'document_id', side_effect=lambda *args: read_document(*args) + 1):
            with self.assertRaisesRegex(ValueError, 'target_changed'):
                c.publish(value, str(self.home), expected)
        self.assertEqual(target.read_bytes(), dynamic)
        (self.home / '.git').mkdir()
        self.assertFalse(c.plan(value, str(self.home))['writes'])

    def test_v5_tracked_source_freshness_and_interruption(self):
        c = self.contract
        raw = b'eval "$(echo ignored)"\n'
        suffix = b"alias fixture='echo A'\n"
        (self.source / '.zshrc').write_bytes(raw + suffix)
        value = c.authorize_capture(c.capture(str(self.source)), str(self.source), [], policy=c.FILE_POLICY)
        for phase in ('stale', 'stage-flags', 'before-swap', 'competing-write', 'after-swap', 'document-mismatch'):
            with self.subTest(phase=phase):
                home = self.root / phase; home.mkdir(mode=0o700)
                target = home / '.zshrc'; target.write_bytes(raw); target.chmod(0o600); os.chflags(target, 0x40)
                expected = c.evidence(value, str(home))
                if phase == 'stale':
                    target.write_bytes(raw + b'# new edit\n')
                    with self.assertRaisesRegex(ValueError, 'target_changed'): c.publish(value, str(home), expected)
                    self.assertEqual(target.read_bytes(), raw + b'# new edit\n')
                    self.assertFalse(list(home.glob('.macseed-shell-pending-*')))
                    continue
                rename = c.sources.rename
                def interrupted(a, source, b, destination, flags):
                    if source == 'swap':
                        if phase == 'before-swap': raise OSError('fixture failure')
                        if phase == 'competing-write': target.write_bytes(raw + b'# competing data\n')
                        result = rename(a, source, b, destination, flags)
                        if phase == 'after-swap': raise OSError('fixture interruption')
                        return result
                    return rename(a, source, b, destination, flags)
                read_document = c.sources.document_id
                def wrong_document(directory, name, info):
                    result = read_document(directory, name, info)
                    if phase == 'document-mismatch' and name == '.zshrc' and target.read_bytes() == raw + suffix:
                        return result + 1
                    return result
                with patch.object(c.sources, 'rename', side_effect=interrupted), patch.object(c.sources, 'document_id', side_effect=wrong_document):
                    if phase == 'stage-flags':
                        with patch.object(c.sources, 'track_staged', side_effect=OSError('fixture flags failure')):
                            with self.assertRaises(c.base.PublicationUncertain): c.publish(value, str(home), expected)
                    else:
                        with self.assertRaises(c.base.PublicationUncertain): c.publish(value, str(home), expected)
                pending, = home.glob('.macseed-shell-pending-*')
                self.assertEqual((pending / 'observed').read_bytes(), raw)
                self.assertEqual(target.stat().st_flags, 0x40)
                if phase in ('stage-flags', 'before-swap'):
                    self.assertEqual(target.read_bytes(), raw)
                else:
                    self.assertEqual(target.read_bytes(), raw + suffix)
                    self.assertEqual((pending / 'swap').read_bytes(), raw + (b'# competing data\n' if phase == 'competing-write' else b''))
                with self.assertRaises(ValueError): c.publish(value, str(home))

    def test_v5_file_plans_isolate_source_and_destination_blockers(self):
        c = self.contract
        dynamic = b'eval "$(touch "$HOME/startup-must-not-run")"\n'
        definition = b"alias fixture='$HOME/bin/linked'\n"
        (self.source / '.zshrc').write_bytes(dynamic + definition)
        (self.source / 'bin').mkdir()
        paths = ['bin/linked', 'bin/independent']
        for path in paths:
            script = self.source / path
            script.write_bytes(b'#!/bin/sh\nprintf "fixture\\n"\n'); script.chmod(0o700)
        value = c.authorize_capture(c.capture(str(self.source)), str(self.source),
            [c.script_id(path) for path in paths], policy=c.FILE_POLICY, script_paths=paths)
        target = self.home / '.zshrc'
        for raw in (dynamic, dynamic + definition, definition * 2):
            with self.subTest(source=raw):
                target.write_bytes(raw)
                planned = c.plan(value, str(self.home))
                self.assertEqual(set(planned['writes']), set(paths) | ({'.zshrc'} if raw == dynamic else set()))
                self.assertEqual(len(planned['rows']), 3)
                self.assertEqual([(state, policy) for row, state, policy in planned['rows'] if row.get('file')],
                                 [('missing', 'create'), ('missing', 'create')])
        target.write_bytes(b'eval "$(unterminated\n')
        ambiguous = c.plan(value, str(self.home))
        self.assertEqual((ambiguous['reason'], ambiguous['writes']), ('ambiguous_context', {}))
        target.write_bytes(dynamic); target.chmod(0o666)
        self.assertEqual(set(c.plan(value, str(self.home))['writes']), set(paths))
        target.chmod(0o600)
        (self.home / 'bin').mkdir()
        linked = self.home / paths[0]
        linked.write_bytes(b'preserve this conflict'); linked.chmod(0o700)
        planned = c.plan(value, str(self.home))
        self.assertEqual(set(planned['writes']), {paths[1]})
        self.assertEqual(next(state for row, state, _ in planned['rows'] if row.get('path') == paths[0]), 'differing')
        before = (linked.read_bytes(), c.base.stamp(linked.stat()), target.read_bytes(), c.base.stamp(target.stat()))
        self.assertTrue(c.publish(value, str(self.home), approvals=[c.script_id(paths[1])]))
        self.assertEqual((linked.read_bytes(), c.base.stamp(linked.stat()), target.read_bytes(), c.base.stamp(target.stat())), before)
        (self.home / paths[1]).unlink(); linked.unlink()
        linked.symlink_to(self.source / paths[0])
        self.assertEqual(set(c.plan(value, str(self.home))['writes']), {paths[1]})
        linked.unlink()
        (self.home / 'bin/.git').mkdir()  # Every destination is now externally managed.
        self.assertFalse(c.plan(value, str(self.home))['writes'])
        with self.assertRaises(ValueError):
            c.publish(value, str(self.home), approvals=[c.script_id(path) for path in paths])
        self.assertFalse((self.home / 'startup-must-not-run').exists())

    def test_alias_check_source_evidence_separate_from_restore_safety(self):
        c = self.contract
        dynamic = b'eval "$(touch "$HOME/startup-must-not-run")"\nhelper() { :; }\n'
        definition = b"alias fixture='echo original'\n"
        source = self.source / '.zshrc'; source.write_bytes(dynamic + definition)
        value = c.capture(str(self.source))
        target = self.home / '.zshrc'
        for policy in (c.OPAQUE_POLICY, c.FILE_POLICY):
            captured = c.authorize_capture(value, str(self.source), [], policy=policy)
            for label, raw, expected in [
                ('identical', dynamic + definition, 'matching'),
                ('removed', dynamic + b'# unrelated settings retained\n', 'missing'),
                ('modified', dynamic + b"alias fixture='echo changed'\n", 'differing'),
                ('conditional', dynamic + b"if true; then alias fixture='echo original'; fi\n", 'unverified'),
                ('duplicate', dynamic + definition * 2, 'unverified'),
                ('dynamic-definition', b'eval "alias fixture=\'echo original\'"\n', 'unverified'),
                ('unbounded-grammar', b'eval "$(unterminated\n', 'unverified'),
                ('unknown-alias-form', b'alias "$UNKNOWN_DEFINITION"\n', 'unverified')]:
                with self.subTest(policy=policy, case=label):
                    target.write_bytes(raw); target.chmod(0o600)
                    before = (raw, c.base.stamp(target.stat()))
                    with patch('subprocess.Popen', side_effect=AssertionError('startup must not execute')):
                        compared = c.comparison(captured, str(self.home))
                    self.assertEqual([(row['name'], state) for row, state, _ in compared['rows']], [('fixture', expected)])
                    self.assertEqual((target.read_bytes(), c.base.stamp(target.stat())), before)
                    self.assertFalse((self.home / 'startup-must-not-run').exists())
                    if label == 'removed':
                        planned = c.plan(captured, str(self.home))
                        if policy == c.FILE_POLICY:
                            self.assertIsNone(planned['reason'])
                            self.assertEqual(planned['writes']['.zshrc'][0], raw + definition)
                        else:
                            self.assertEqual((planned['reason'], planned['writes']), ('source_prerequisite', {}))
                            self.assertEqual(planned['rows'][0][1], 'unverified')
                            with self.assertRaisesRegex(ValueError, 'source_prerequisite'):
                                c.publish(captured, str(self.home))
                        self.assertEqual(target.read_bytes(), raw)
            target.write_bytes(dynamic)
            for unsafe in ('permissions', 'compiled', 'symlink', 'owner', 'unreadable'):
                with self.subTest(policy=policy, unsafe=unsafe):
                    if unsafe == 'permissions': target.chmod(0o666)
                    if unsafe == 'compiled': (self.home / '.zshrc.zwc').touch()
                    if unsafe == 'symlink': target.unlink(); target.symlink_to(source)
                    try:
                        if unsafe == 'owner':
                            with patch.object(c.base.os, 'getuid', return_value=123456):
                                compared = c.comparison(captured, str(self.home))
                        elif unsafe == 'unreadable':
                            with patch.object(c.sources, 'file_state', side_effect=PermissionError):
                                compared = c.comparison(captured, str(self.home))
                        else: compared = c.comparison(captured, str(self.home))
                        self.assertEqual(compared['rows'][0][1], 'unverified')
                    finally:
                        if unsafe == 'permissions': target.chmod(0o600)
                        if unsafe == 'compiled': (self.home / '.zshrc.zwc').unlink()
                        if unsafe == 'symlink': target.unlink(); target.write_bytes(dynamic)

    def test_alias_check_requires_bound_source_chain_and_fresh_observation(self):
        c = self.contract
        value = c.authorize_capture(self.fixture(), str(self.source), [], policy=c.FILE_POLICY)
        leaf = self.source / '.config/zsh/aliases'
        leaf.write_bytes(b'# definition removed\n')
        self.assertEqual(c.comparison(value, str(self.source))['rows'][0][1], 'missing')
        (self.source / '.zshrc').write_bytes(b'# source is no longer connected\n')
        self.assertEqual(c.comparison(value, str(self.source))['rows'][0][1], 'unverified')
        (self.source / '.zshrc').write_text('source "$HOME/.config/zsh/aliases"\n' * 2)
        self.assertEqual(c.comparison(value, str(self.source))['rows'][0][1], 'unverified')
        (self.source / '.zshrc').write_text('source "$HOME/.config/zsh/aliases"\n')
        reader = c.sources.file_state
        def unstable(home, path, *args, **kwargs):
            if path == '.config/zsh/aliases': leaf.write_bytes(leaf.read_bytes() + b'# changing\n')
            return reader(home, path, *args, **kwargs)
        with patch.object(c.sources, 'file_state', side_effect=unstable):
            self.assertEqual(c.comparison(value, str(self.source))['rows'][0][1], 'unverified')
        with patch.dict(os.environ, ZDOTDIR='/unqualified-startup'):
            self.assertEqual(c.comparison(value, str(self.source))['rows'][0][1], 'unverified')

    def xattrs(self, path):
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try: return {key.decode(): value for key, value in self.contract.sources.attributes(fd).items()}
        finally: os.close(fd)

    def set_xattr(self, path, name, raw):
        subprocess.run(['/usr/bin/xattr', '-wx', name, raw.hex(), str(path)], check=True, capture_output=True)

    def remove_xattr(self, path, name):
        subprocess.run(['/usr/bin/xattr', '-d', name, str(path)], check=True, capture_output=True)

    def test_v5_explicit_harmless_xattrs_and_legacy_policy(self):
        c = self.contract
        directory = self.source / 'Scripts'; directory.mkdir(mode=0o700)
        allowed = {'clean.sh': {}, 'encoding.sh': {'com.apple.TextEncoding': b'UTF-8;134217984'},
                   'download.sh': {'com.apple.metadata:kMDItemWhereFroms': plistlib.dumps(['https://example.invalid/script.sh']),
                                   'com.apple.metadata:kMDItemDownloadedDate': plistlib.dumps(['fixture-date']),
                                   'com.apple.lastuseddate#PS': b'\0' * 16}}
        paths = []
        original = {}
        for name, attrs in allowed.items():
            path = directory / name; path.write_bytes(b'#!/bin/sh\necho fixture\n'); path.chmod(0o750)
            for key, value in attrs.items(): self.set_xattr(path, key, value)
            original[name] = (path.read_bytes(), path.stat(), self.xattrs(path))
            paths.append('Scripts/' + name)
            with c.sources.parent(str(self.source), paths[-1], read_only=True) as (fd, leaf, _):
                c.opaque_metadata(fd, leaf, version=5)
                if attrs:
                    with self.assertRaisesRegex(ValueError, 'unsupported_metadata'): c.opaque_metadata(fd, leaf, version=4)
        value = c.empty_capture()
        requested = {row['id']: row['observation_id'] for row in c.selection_candidates(value, str(self.source), paths, c.FILE_POLICY)}
        self.assertEqual([row['status'] for row in c.inspect_scripts(value, str(self.source), requested, c.FILE_POLICY, paths)], ['qualified'] * 3)
        captured = c.authorize_capture(value, str(self.source), list(requested), policy=c.FILE_POLICY, script_paths=paths)
        self.assertNotIn(b'example.invalid', c.encode(captured), 'Origin URLs stay out of the Bundle and public evidence')
        self.assertTrue(c.publish(captured, str(self.home), approvals=list(requested)))
        for name, (raw, before, attrs) in original.items():
            source, target = directory / name, self.home / 'Scripts' / name
            self.assertEqual((source.read_bytes(), c.base.stamp(source.stat())), (raw, c.base.stamp(before)))
            self.assertEqual(self.xattrs(source), attrs)
            self.assertEqual((target.read_bytes(), stat.S_IMODE(target.stat().st_mode)), (raw, 0o750))
            # Harmless metadata on an existing destination neither forces a rewrite
            # nor changes file conformity. No source annotation is restored.
            self.set_xattr(target, 'com.apple.TextEncoding', b'UTF-8;134217984')
        self.assertEqual([row[1] for row in c.comparison(captured, str(self.home))['rows']], ['matching'] * 3)
        self.assertFalse(c.publish(captured, str(self.home)))

    def test_v5_invalid_quarantine_and_unknown_xattrs_fail_closed(self):
        c = self.contract
        path = self.source / 'script.sh'; path.write_bytes(b'#!/bin/sh\necho fixture\n'); path.chmod(0o700)
        value, paths = c.empty_capture(), ['script.sh']
        for name, raw, reason in [('com.apple.quarantine', b'invalid quarantine', 'script_quarantine_invalid'),
                                  ('com.macseed.fixture', b'unknown', 'script_metadata_unsupported'),
                                  ('com.apple.ResourceFork', b'resource', 'script_metadata_unsupported'),
                                  ('com.apple.TextEncoding', b'x' * 32769, 'script_metadata_unsupported')]:
            with self.subTest(attribute=name):
                self.set_xattr(path, name, raw)
                requested = {row['id']: row['observation_id'] for row in c.selection_candidates(value, str(self.source), paths, c.FILE_POLICY)}
                row, = c.inspect_scripts(value, str(self.source), requested, c.FILE_POLICY, paths)
                self.assertEqual((row['status'], row['reason']), ('unsupported', reason))
                with self.assertRaises(ValueError):
                    c.authorize_capture(value, str(self.source), list(requested), policy=c.FILE_POLICY, script_paths=paths)
                observed = subprocess.run(['/usr/bin/xattr', '-px', name, str(path)], check=True, capture_output=True).stdout
                self.assertEqual(bytes.fromhex(observed.decode()), raw)
                self.remove_xattr(path, name)  # Disposable fixture only.

    def test_v5_bounded_manifest_and_original_content_budgets(self):
        c = self.contract
        def value(count, size):
            text = '#!/bin/sh\n#' + 'x' * (size - 12) + '\n'
            self.assertEqual(len(text.encode()), size)
            rows = [dict(path=f'Scripts/file-{i}.sh', text=text, mode=0o640, managed=False,
                         sha256=hashlib.sha256(text.encode()).hexdigest()) for i in range(count)]
            return dict(c.empty_capture(), version=5, scripts=rows)
        maximum = value(16, c.MAX_FILE_BYTES)
        self.assertEqual(sum(len(raw) for raw in c.contents(maximum).values()), c.MAX_CONTENT_BYTES)
        self.assertEqual(c.validated(maximum), maximum)
        self.assertNotIn(b'xxxx', c.encode(maximum))
        for invalid in (value(1, c.MAX_FILE_BYTES + 1), value(17, c.MAX_FILE_BYTES), value(129, 24)):
            with self.assertRaises(ValueError): c.snapshot(c.encode(invalid), {})
        many = value(128, 24)
        self.assertEqual(c.validated(many), many)
        # Worst legal HOME-relative path: 512 ASCII bytes, components <= 128.
        for index, row in enumerate(many['scripts']):
            row['path'] = '/'.join(['a' * 128, 'b' * 128, 'c' * 128, str(index).zfill(3) + 'd' * 119 + '.sh'])
            row['quarantine'] = c.quarantine_record(b'12345678;1234567890abcdef;' + b'a' * 128 + b';12345678-1234-1234-1234-123456789012')
            self.assertEqual(len(row['path']), 512)
        manifest = c.encode(many)
        self.assertLess(len(manifest) + shell_aliases.MAX_BYTES + c.MAX_FILES * 7, c.MAX_MANIFEST_BYTES)
        self.assertEqual(len(c.validated(many)['scripts']), 128)
        with self.assertRaises(ValueError): c.snapshot(manifest + b' ' * c.MAX_MANIFEST_BYTES, {})
        payloads = c.contents(many)
        for mutation in ('hash', 'member', 'path', 'duplicate', 'consent'):
            changed = json.loads(manifest[len(c.FILE_MAGIC):])
            row = changed['scripts'][0]
            if mutation == 'hash': row['sha256'] = '0' * 64
            if mutation == 'member': row['member'] = 'generated/shell/scripts/../../outside'
            if mutation == 'path': row['path'] = '../outside.sh'
            if mutation == 'duplicate': changed['scripts'][1] = dict(row)
            if mutation == 'consent': row['consent'] = 'implicit'
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                c.snapshot(c.FILE_MAGIC + json.dumps(changed).encode(), payloads)
        with self.assertRaises(ValueError): c.snapshot(manifest, dict(payloads, unexpected=b'x'))
        # Legacy capability 4 keeps its original count/content/mode/snapshot limits.
        for invalid in (dict(maximum, version=4), dict(value(1, 24), version=4)):
            with self.assertRaises(ValueError): c.snapshot(c.encode(invalid))

    def test_v5_quarantine_capture_publication_check_and_integrity(self):
        c = self.contract
        path = self.source / 'nested/script.py'; path.parent.mkdir(mode=0o700)
        raw = b'print("never execute")\n'; path.write_bytes(raw); path.chmod(0o640)
        quarantine = b'0083;12345678;;12345678-1234-1234-1234-123456789012'
        self.set_xattr(path, 'com.apple.quarantine', quarantine)
        self.set_xattr(path, 'com.apple.TextEncoding', b'UTF-8;134217984')
        before = (c.base.stamp(path.stat()), self.xattrs(path))
        value, paths = c.empty_capture(), ['nested/script.py']
        requested = {row['id']: row['observation_id'] for row in c.selection_candidates(value, str(self.source), paths, c.FILE_POLICY)}
        inspected, = c.inspect_scripts(value, str(self.source), requested, c.FILE_POLICY, paths)
        self.assertEqual(inspected['status'], 'qualified')
        captured = c.authorize_capture(value, str(self.source), list(requested), policy=c.FILE_POLICY, script_paths=paths)
        record = captured['scripts'][0]['quarantine']
        self.assertEqual(c.quarantine_bytes(record), quarantine)
        stored = self.root / 'staged/shell/zshrc.snapshot'; c.save(stored, captured)
        captured = c.load(stored)
        self.assertEqual((c.base.stamp(path.stat()), self.xattrs(path)), before)
        with self.assertRaises(ValueError): c.publish(captured, str(self.home))
        self.assertFalse((self.home / 'nested').exists())
        target = self.home / paths[0]
        rename = c.sources.rename
        def checked_rename(directory, name, dest, filename, flag):
            if name == 'swap':
                descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
                try: self.assertEqual(c.sources.attributes(descriptor)[b'com.apple.quarantine'], quarantine)
                finally: os.close(descriptor)
                self.assertFalse(target.exists(), 'Protection must precede no-clobber publication')
            return rename(directory, name, dest, filename, flag)
        with patch.object(c.sources, 'rename', side_effect=checked_rename):
            self.assertTrue(c.publish(captured, str(self.home), approvals=list(requested)))
        self.assertEqual(self.xattrs(target)['com.apple.quarantine'], quarantine)
        self.assertEqual((target.read_bytes(), stat.S_IMODE(target.stat().st_mode)), (raw, 0o640))
        self.assertEqual(c.comparison(captured, str(self.home))['rows'][0][1], 'matching')
        stamp = c.base.stamp(target.stat())
        self.assertFalse(c.publish(captured, str(self.home)))
        self.assertEqual(c.base.stamp(target.stat()), stamp)
        for missing in (True, False):
            if missing: self.remove_xattr(target, 'com.apple.quarantine')
            else: self.set_xattr(target, 'com.apple.quarantine', b'0081;12345678;Changed;')
            self.assertEqual(c.comparison(captured, str(self.home))['rows'][0][1], 'differing')
            attrs = self.xattrs(target)
            with self.assertRaises(ValueError): c.publish(captured, str(self.home), approvals=list(requested))
            self.assertEqual(self.xattrs(target), attrs, 'Never repair quarantine by overwriting an existing destination')
        self.set_xattr(target, 'com.apple.quarantine', b'malformed')
        self.assertEqual(c.comparison(captured, str(self.home))['rows'][0][1], 'unverified')
        self.set_xattr(target, 'com.apple.quarantine', quarantine)
        for mutation in ('missing', 'hash', 'data', 'version', 'extra', 'oversize'):
            changed = json.loads(c.encode(captured)[len(c.FILE_MAGIC):]); item = changed['scripts'][0]
            if mutation == 'missing': del item['quarantine']
            if mutation == 'hash': item['quarantine']['sha256'] = '0' * 64
            if mutation == 'data': item['quarantine']['data'] = c.base64.b64encode(b'0081;12345678;Changed;').decode()
            if mutation == 'version': item['quarantine']['version'] = 2
            if mutation == 'extra': item['quarantine']['com.apple.ResourceFork'] = 'injection'
            if mutation == 'oversize': item['quarantine']['data'] = 'A' * 1024
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                c.snapshot(c.FILE_MAGIC + json.dumps(changed).encode(), c.contents(captured))
        # Source metadata changes invalidate the observation, not just its bytes.
        self.set_xattr(path, 'com.apple.quarantine', b'0081;12345678;Changed;')
        self.assertEqual(c.inspect_scripts(value, str(self.source), requested, c.FILE_POLICY, paths)[0]['reason'], 'script_changed')

    def test_v5_quarantine_publication_failures_never_report_success(self):
        c = self.contract
        path = self.source / 'script.sh'; path.write_bytes(b'#!/bin/sh\necho fixture\n'); path.chmod(0o700)
        self.set_xattr(path, 'com.apple.quarantine', b'0083;12345678;Fixture;')
        ids = [c.script_id(path.name)]
        captured = c.authorize_capture(c.empty_capture(), str(self.source), ids, policy=c.FILE_POLICY, script_paths=[path.name])
        lib = c.sources.native()
        with patch.object(c.sources, 'native', return_value=lib), patch.object(lib, 'fsetxattr', return_value=-1):
            with self.assertRaises(ValueError): c.publish(captured, str(self.home), approvals=ids)
        self.assertFalse((self.home / path.name).exists())
        fresh = self.root / 'verification-failure'; fresh.mkdir(mode=0o700)
        verify = c.verify_quarantine
        def failed(fd, record):
            verify(fd, record)
            if (fresh / path.name).exists(): raise ValueError('fixture post-publication xattr observation failure')
        with patch.object(c, 'verify_quarantine', side_effect=failed):
            with self.assertRaises(ValueError): c.publish(captured, str(fresh), approvals=ids)
        self.assertEqual(self.xattrs(fresh / path.name)['com.apple.quarantine'], b'0083;12345678;Fixture;')
        self.assertEqual((fresh / path.name).read_bytes(), path.read_bytes())

    def test_v5_nonexecutable_transfer_safety_and_independent_check(self):
        c = self.contract
        directory = self.source / 'Scripts'; directory.mkdir(mode=0o700)
        payloads = {'plain.sh': (b'echo fixture\n', 0o600), 'python.py': (b'print("fixture")\n', 0o640),
                    'extensionless': (b'#!/usr/bin/env python3\r\nprint("fixture")\r\n', 0o750),
                    'large.zsh': (b'#!/bin/zsh\n#' + b'x' * 70000 + b'\n', 0o700)}
        for name, (raw, mode) in payloads.items():
            path = directory / name; path.write_bytes(raw); path.chmod(mode)
        value = c.empty_capture()
        paths = c.manual_paths(value, str(self.source), [str(directory / name) for name in payloads])
        candidates = c.selection_candidates(value, str(self.source), paths, c.FILE_POLICY)
        self.assertEqual(len(candidates), 4)
        ids = [row['id'] for row in candidates]
        captured = c.authorize_capture(value, str(self.source), ids, policy=c.FILE_POLICY, script_paths=paths)
        stored = self.root / 'staged/shell/zshrc.snapshot'; c.save(stored, captured)
        self.assertEqual(c.load(stored), captured)
        with patch('subprocess.Popen', side_effect=AssertionError('scripts must never execute')):
            with self.assertRaises(ValueError): c.publish(captured, str(self.home))
            self.assertFalse((self.home / 'Scripts').exists())
            self.assertTrue(c.publish(captured, str(self.home), approvals=ids))
            self.assertFalse(c.publish(captured, str(self.home)))
            self.assertEqual([row[1] for row in c.comparison(captured, str(self.home))['rows']], ['matching'] * 4)
        self.assertEqual(stat.S_IMODE((self.home / 'Scripts').stat().st_mode), 0o700)
        for name, (raw, mode) in payloads.items():
            target = self.home / 'Scripts' / name
            self.assertEqual((target.read_bytes(), stat.S_IMODE(target.stat().st_mode)), (raw, mode))
        (self.home / 'Scripts/plain.sh').chmod(0o700)
        self.assertEqual(c.script_state(next(row for row in captured['scripts'] if row['path'].endswith('plain.sh')), str(self.home)), 'differing')
        (self.home / 'Scripts/python.py').unlink()
        self.assertEqual(c.script_state(next(row for row in captured['scripts'] if row['path'].endswith('python.py')), str(self.home)), 'missing')
        (self.home / 'Scripts/python.py').write_bytes(b'competing data\n')
        with self.assertRaises(ValueError): c.publish(captured, str(self.home), approvals=ids)
        self.assertEqual((self.home / 'Scripts/python.py').read_bytes(), b'competing data\n')
        # Non-executable files can transfer; an alias still cannot invoke one.
        (self.source / '.zshrc').write_text("alias plain='$HOME/Scripts/plain.sh'\n")
        alias = c.capture(str(self.source))
        self.assertEqual(c.sources.dependency_states(alias, str(self.source))['Scripts/plain.sh'][0], 'unverified')
        self.assertEqual(c.inspect_scripts(alias, str(self.source), {row['id']: row['observation_id'] for row in c.selection_candidates(alias, str(self.source), policy=c.FILE_POLICY)}, c.FILE_POLICY)[0]['status'], 'qualified')
        with_alias = c.authorize_capture(alias, str(self.source), [c.script_id('Scripts/plain.sh')], policy=c.FILE_POLICY)
        empty = self.root / 'empty'; empty.mkdir(mode=0o700)
        self.assertEqual(c.plan(with_alias, str(empty))['reason'], 'dependency_prerequisite')
        self.assertTrue(c.publish(with_alias, str(empty), approvals=[c.script_id('Scripts/plain.sh')]))
        self.assertFalse((empty / '.zshrc').exists(), 'Transfer never makes a non-executable dependency invocable')
        self.assertEqual((empty / 'Scripts/plain.sh').stat().st_mode & 0o777, 0o600)
        self.assertEqual((empty / 'Scripts/plain.sh').read_bytes(), (self.source / 'Scripts/plain.sh').read_bytes())
        (empty / 'Scripts/plain.sh').unlink()
        (empty / 'Scripts/.git').mkdir(parents=True)
        managed_before = set((empty / 'Scripts').iterdir())
        self.assertIsNotNone(c.plan(captured, str(empty))['reason'])
        with self.assertRaises(ValueError): c.publish(captured, str(empty), approvals=ids)
        self.assertEqual(set((empty / 'Scripts').iterdir()), managed_before)
        unsafe = directory / 'unsafe.sh'; unsafe.write_bytes(b'echo fixture\n'); unsafe.chmod(0o666)
        link = directory / 'link.sh'; link.symlink_to(directory / 'plain.sh')
        for path in (unsafe, link):
            self.assertEqual(c.script_candidates(value, str(self.source), ['Scripts/' + path.name], c.FILE_POLICY), [])
        binary = directory / 'binary.py'; binary.write_bytes(b'\xff\x00'); binary.chmod(0o600)
        candidate, = c.selection_candidates(value, str(self.source), ['Scripts/binary.py'], c.FILE_POLICY)
        rejected, = c.inspect_scripts(value, str(self.source), {candidate['id']: candidate['observation_id']}, c.FILE_POLICY, ['Scripts/binary.py'])
        self.assertEqual((rejected['status'], rejected['reason']), ('unsupported', 'script_format_unsupported'))
        with patch.object(c.os, 'getuid', return_value=123456):
            self.assertEqual(c.script_candidates(value, str(self.source), ['Scripts/plain.sh'], c.FILE_POLICY), [])
        # Canonical identity survives repeat Add with a different spelling on a
        # case-insensitive volume; hard links and symbolic links remain rejected.
        alternate = directory / 'PLAIN.sh'
        if alternate.exists():
            self.assertEqual(c.manual_paths(value, str(self.source), [str(alternate)]), ['Scripts/plain.sh'])

    def test_comparison_preserves_historical_capability_predicates(self):
        value = self.fixture(script=True)
        key = self.contract.script_id('.local/bin/adns')
        legacy = self.contract.authorize_capture(value, str(self.source), [key])
        rows, partial = shell_aliases.classify(b"alias ll='ls -la'\n")
        versions = [shell_aliases.encode(rows, partial),
                    self.contract.sources.encode(self.contract.source_value(value)), self.contract.encode(legacy)]
        snapshot = self.root / 'legacy.snapshot'
        for version, raw in enumerate(versions, 1):
            with self.subTest(version=version):
                snapshot.write_bytes(raw); snapshot.chmod(0o600)
                results = [subprocess.run([sys.executable, '-B', str(ROOT / 'modules/shell/aliases.py'), command, str(snapshot)],
                    env=dict(os.environ, HOME=str(self.source)), capture_output=True, text=True) for command in ('inspect', 'compare')]
                self.assertTrue(all(result.returncode == 0 for result in results))
                self.assertEqual(results[0].stdout, results[1].stdout)
                self.assertNotIn('shell-script:', results[1].stdout)

    def test_mixed_comparison_reads_shared_authorized_file_once(self):
        value = self.fixture(script=True)
        leaf = self.source / '.config/zsh/aliases'
        leaf.write_text(leaf.read_text() + "alias another='$HOME/.local/bin/adns'\n")
        value = self.contract.capture(str(self.source))
        key = self.contract.script_id('.local/bin/adns')
        captured = self.contract.authorize_capture(value, str(self.source), [key], policy=self.contract.OPAQUE_POLICY)
        reader = self.contract.sources.file_state
        reads = []
        def read(home, path, *args, **kwargs):
            if path == '.local/bin/adns': reads.append(path)
            return reader(home, path, *args, **kwargs)
        with patch.object(self.contract.sources, 'file_state', side_effect=read):
            compared = self.contract.comparison(captured, str(self.source))
        files = [row for row in compared['rows'] if row[0].get('file')]
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0][1], 'matching')
        self.assertEqual(reads, ['.local/bin/adns'])
        self.assertEqual(len(compared['rows']), 4, 'Three aliases plus one independently authorized file')
        self.assertEqual(len(self.contract.plan(captured, str(self.source))['rows']), 3, 'Preview identities stay unchanged')
        self.assertFalse(any(row[0].get('file') for row in self.contract.comparison(value, str(self.source))['rows']))
        # A change between the byte observation and metadata qualification fails closed.
        metadata = self.contract.opaque_metadata
        def replaced(fd, name, **kwargs):
            metadata(fd, name, **kwargs)
            (self.source / '.local/bin/adns').write_text('#!/bin/sh\n/bin/date\n')
        with patch.object(self.contract, 'opaque_metadata', side_effect=replaced):
            self.assertEqual(self.contract.comparison(captured, str(self.source))['rows'][-1][1], 'unverified')
        def disappeared(fd, name, **kwargs):
            metadata(fd, name, **kwargs)
            (self.source / '.local/bin/adns').unlink()
        with patch.object(self.contract, 'opaque_metadata', side_effect=disappeared):
            self.assertEqual(self.contract.comparison(captured, str(self.source))['rows'][-1][1], 'unverified')
        with patch.object(self.contract.sources, 'file_state', side_effect=PermissionError):
            # The parent still exists, but an unreadable file is not absence.
            (self.source / '.local/bin/adns').write_text('#!/bin/sh\n/bin/date\n')
            self.assertEqual(self.contract.script_state(captured['scripts'][0], str(self.source)), 'unverified')

    def test_opaque_file_only_inspection_has_only_selected_scope(self):
        value = self.fixture(script=True)
        key = self.contract.script_id('.local/bin/adns')
        captured = self.contract.authorize_capture(value, str(self.source), [key], policy=self.contract.OPAQUE_POLICY)
        only = self.contract.select(captured, {'shell-script:' + key})
        snapshot = self.root / 'selected.snapshot'
        def inspect(value):
            snapshot.write_bytes(self.contract.encode(value)); snapshot.chmod(0o600)
            result = subprocess.run([sys.executable, '-B', str(ROOT / 'modules/shell/aliases.py'), 'inspect', str(snapshot)],
                                    env=dict(os.environ, HOME=str(self.home)), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return [line.split('\t') for line in result.stdout.splitlines()]
        self.assertEqual(inspect(only), [['shell-script:' + key, 'missing', 'create']])
        # This is a known target fixture, not another restoration/Apply run.
        target = self.home / '.local/bin/adns'
        target.parent.mkdir(parents=True)
        target.write_bytes((self.source / '.local/bin/adns').read_bytes()); target.chmod(0o700)
        self.assertEqual(inspect(only), [['shell-script:' + key, 'matching', 'preserve']])
        self.assertTrue(any(row[:2] == ['scope', 'partial'] for row in inspect(captured)),
                        'Selected aliases retain their independent startup coverage diagnostic')
        target.chmod(0o777)
        rows = inspect(only)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][:2], ['shell-script:' + key, 'unverified'])
        self.assertEqual(rows[0][2], 'preserve', 'An unsafe file must never become planned work')
        self.assertFalse((self.home / '.zshrc').exists())

    def test_opaque_standalone_file_without_alias_or_startup_mutation(self):
        value = self.fixture(script=True)
        key = self.contract.script_id('.local/bin/adns')
        captured = self.contract.authorize_capture(value, str(self.source), [key], policy=self.contract.OPAQUE_POLICY)
        self.assertEqual(len(self.contract.requirement_ids(captured)), 2)
        only = self.contract.select(captured, {'shell-script:' + key})
        self.assertEqual((only['aliases'], only['layout']), ([], []))
        self.assertEqual(self.contract.requirement_ids(only), ['shell-script:' + key])
        self.assertEqual(self.contract.selection_candidates(only)[0]['alias_ids'], [])
        self.assertTrue(self.contract.selection_candidates(only)[0]['independent'])
        self.assertTrue(self.contract.publish(only, str(self.home), approvals=[key]))
        self.assertFalse((self.home / '.zshrc').exists())
        self.assertFalse((self.home / '.config').exists())
        self.assertEqual(self.contract.assess(only, str(self.home))[0][1], 'matching')
        self.assertFalse(self.contract.publish(only, str(self.home)))
        with self.assertRaises(ValueError): self.contract.snapshot(self.contract.encode(dict(only, version=3)))

    def test_opaque_file_contract_roundtrip_and_legacy_boundary(self):
        value = self.fixture(script=True)
        script = self.source / '.local/bin/adns'
        raw = ('#!/bin/bash\r\n# Проверка — fixture only\r\n'
               'touch "$HOME/opaque-script-must-not-run"\r\n'
               'report() { for name in alpha beta; do printf "%s\\n" "$name"; done; }\r\n'
               'if [ -n "$HOME" ]; then report; fi\r\n'
               'fixture-unavailable-command --flag\r\n').encode()
        script.write_bytes(raw); script.chmod(0o755)
        candidate = self.contract.selection_candidates(value, str(self.source))[0]
        with patch.object(self.contract.base, 'read_file', side_effect=AssertionError('metadata read body')):
            self.assertEqual(self.contract.selection_candidates(value, str(self.source)), [candidate])
        request = {candidate['id']: candidate['observation_id']}
        self.assertEqual(self.contract.inspect_scripts(value, str(self.source), request)[0]['status'], 'unsupported')
        self.assertEqual(self.contract.inspect_scripts(value, str(self.source), request, self.contract.OPAQUE_POLICY)[0]['status'], 'qualified')
        with self.assertRaises(ValueError): self.contract.authorize_capture(value, str(self.source), [candidate['id']])
        captured = self.contract.authorize_capture(value, str(self.source), [candidate['id']], policy=self.contract.OPAQUE_POLICY)
        self.assertEqual(captured['version'], 4)
        self.assertEqual(captured['scripts'][0]['text'].encode(), raw)
        self.assertEqual(self.contract.snapshot(self.contract.encode(captured)), captured)
        with self.assertRaises(ValueError): self.contract.snapshot(self.contract.encode(dict(captured, version=3)))
        with self.assertRaises(ValueError): self.contract.publish(captured, str(self.home))
        self.assertFalse(list(self.home.iterdir()))
        self.assertTrue(self.contract.publish(captured, str(self.home), approvals=[candidate['id']]))
        target = self.home / candidate['path']
        self.assertEqual(target.read_bytes(), raw)
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o755)
        self.assertTrue(all(state == 'matching' for _, state, _ in self.contract.assess(captured, str(self.home))))
        self.assertFalse(self.contract.publish(captured, str(self.home)))
        self.assertFalse((self.source / 'opaque-script-must-not-run').exists())
        self.assertFalse((self.home / 'opaque-script-must-not-run').exists())
        target.write_bytes(raw + b'# changed\n')
        self.assertEqual(self.contract.plan(captured, str(self.home))['reason'], 'script_conflict')
        with self.assertRaises(ValueError): self.contract.publish(captured, str(self.home), approvals=[candidate['id']])
        self.assertEqual(target.read_bytes(), raw + b'# changed\n')

    def test_opaque_file_privacy_metadata_and_freshness(self):
        value = self.fixture(script=True)
        script = self.source / '.local/bin/adns'
        policy = self.contract.OPAQUE_POLICY
        for body in ["API_TOKEN='fixture-private-value'", 'PASSWORD=fixture-private-value',
                     '# -----BEGIN OPENSSH PRIVATE KEY-----', 'curl https://user:pass@example.invalid',
                     'Authorization: Bearer abcdefgh12345678', '"token": "fixture-private-value"',
                     'password: fixture-private-value']:
            script.write_text('#!/bin/bash\n' + body + '\n')
            row = self.contract.selection_candidates(value, str(self.source))[0]
            result = self.contract.inspect_scripts(value, str(self.source), {row['id']: row['observation_id']}, policy)[0]
            self.assertEqual((result['status'], result['reason']), ('unsupported', 'script_sensitive_indicator'))
            self.assertNotIn(body, json.dumps(result))
            with self.assertRaises(ValueError): self.contract.authorize_capture(value, str(self.source), [row['id']], policy=policy)
        script.write_text('#!/bin/bash\n# nonsecret credential variable\nTOKEN="$RUNTIME_TOKEN"\n')
        row = self.contract.selection_candidates(value, str(self.source))[0]
        self.assertEqual(self.contract.inspect_scripts(value, str(self.source), {row['id']: row['observation_id']}, policy)[0]['status'], 'qualified')
        script.write_text('#!/bin/bash\n' + '#' * 8192)
        row = self.contract.selection_candidates(value, str(self.source))[0]
        self.assertEqual(self.contract.inspect_scripts(value, str(self.source), {row['id']: row['observation_id']}, policy)[0]['reason'], 'script_limit')
        script.write_text('#!/bin/bash\n# safe fixture\necho ok\n')
        row = self.contract.selection_candidates(value, str(self.source))[0]
        observed = self.contract.sources.dependency_states(value, str(self.source))
        script.write_text('#!/bin/bash\necho changed\n')
        self.assertEqual(self.contract.inspect_scripts(value, str(self.source), {row['id']: row['observation_id']}, policy)[0]['reason'], 'script_changed')
        with self.assertRaises(ValueError): self.contract.authorize_capture(value, str(self.source), [row['id']], observed, policy)
        for path in ['.ssh/automation', '.env', '.aws/helper', '.config/.env.local/tool']:
            self.assertFalse(self.contract.opaque_path(path))
        self.assertTrue(self.contract.opaque_path('.local/bin/automation'))
        reader = self.contract.base.read_file
        def concurrent(name, fd, **kwargs):
            raw = reader(name, fd, **kwargs); script.write_bytes(raw + b'# concurrent\n'); return raw
        fresh = self.contract.selection_candidates(value, str(self.source))[0]
        with patch.object(self.contract.base, 'read_file', side_effect=concurrent):
            result = self.contract.inspect_scripts(value, str(self.source), {fresh['id']: fresh['observation_id']}, policy)[0]
        self.assertEqual(result['status'], 'unverified')
        self.assertFalse(list(self.home.iterdir()))

    def test_opaque_file_filesystem_and_aggregate_limits(self):
        value = self.fixture(script=True)
        source = self.source / '.local/bin/adns'
        policy, key = self.contract.OPAQUE_POLICY, self.contract.script_id('.local/bin/adns')
        raw = source.read_bytes()
        captured = self.contract.authorize_capture(value, str(self.source), [key], policy=policy)
        def blocked():
            with self.assertRaises(ValueError):
                self.contract.authorize_capture(value, str(self.source), [key], policy=policy)
            self.assertFalse(list(self.home.iterdir()))
        other = self.source / 'other'; other.write_bytes(raw); other.chmod(0o700)
        source.unlink(); source.symlink_to(other); blocked()
        source.unlink(); os.link(other, source); blocked()
        source.unlink(); source.write_bytes(raw); source.chmod(0o777); blocked(); source.chmod(0o700)
        subprocess.run(['/bin/chmod', '+a', 'everyone allow read', str(source)], check=True, capture_output=True)
        try: blocked()
        finally: subprocess.run(['/bin/chmod', '-N', str(source)], check=True, capture_output=True)
        os.chflags(source, 0x40)
        try: blocked()
        finally: os.chflags(source, 0)
        source.parent.chmod(0o777); blocked(); source.parent.chmod(0o700)
        subprocess.run(['/usr/bin/xattr', '-w', 'com.macseed.fixture', 'metadata', str(source)], check=True, capture_output=True)
        try: blocked()
        finally: subprocess.run(['/usr/bin/xattr', '-d', 'com.macseed.fixture', str(source)], check=True, capture_output=True)
        # Read-only observation of an owned repository does not authorize mutation.
        (source.parent / '.git').mkdir()
        managed = self.contract.authorize_capture(value, str(self.source), [key], policy=policy)
        self.assertTrue(managed['scripts'][0]['managed'])
        self.assertEqual(self.contract.plan(managed, str(self.home))['reason'], 'managed_source_prerequisite')
        (source.parent / '.git').rmdir()
        # Target management and metadata remain blockers, even with matching bytes.
        (self.home / '.local/bin').mkdir(parents=True)
        (self.home / '.local/.git').mkdir()
        with self.assertRaises(ValueError): self.contract.publish(captured, str(self.home), approvals=[key])
        self.assertFalse((self.home / '.zshrc').exists())
        (self.home / '.local/.git').rmdir()
        target = self.home / '.local/bin/adns'; target.write_bytes(raw); target.chmod(0o700)
        os.chflags(target, 0x40)
        try:
            self.assertEqual(self.contract.plan(captured, str(self.home))['reason'], 'unsupported_metadata')
            with self.assertRaises(ValueError): self.contract.publish(captured, str(self.home), approvals=[key])
        finally: os.chflags(target, 0)
        # Many individually bounded files must also fit the 64 KiB snapshot budget.
        lines = []
        for index in range(17):
            name = 'file' + str(index)
            path = self.source / '.local/bin' / name
            path.write_text('#!/bin/bash\n#' + 'x' * 7990); path.chmod(0o700)
            lines.append("alias " + name + "='$HOME/.local/bin/" + name + "'\n")
        (self.source / '.config/zsh/aliases').write_text(''.join(lines))
        many = self.contract.capture(str(self.source))
        rows = self.contract.selection_candidates(many, str(self.source))
        self.assertEqual(len(rows), 16)
        requested = {row['id']: row['observation_id'] for row in rows}
        results = self.contract.inspect_scripts(many, str(self.source), requested, policy)
        self.assertTrue(all(row['reason'] == 'script_limit' for row in results))
        with self.assertRaises(ValueError): self.contract.authorize_capture(many, str(self.source), list(requested), policy=policy)

    def test_script_inspection_is_bounded_explicit_and_fresh(self):
        value = self.fixture(script=True)
        candidates = self.contract.selection_candidates(value, str(self.source))
        requested = {row['id']: row['observation_id'] for row in candidates}
        script = self.source / '.local/bin/adns'
        original = script.read_bytes()
        with patch.object(self.contract.base, 'read_file', side_effect=AssertionError('Unrequested content read')):
            self.assertEqual(self.contract.inspect_scripts(value, str(self.source), {}), [])
            self.assertEqual(self.contract.selection_candidates(value, str(self.source)), candidates)
        self.assertEqual(self.contract.inspect_scripts(value, str(self.source), requested)[0]['status'], 'qualified')
        self.assertEqual(value['scripts'], [], 'Inspection is not Capture consent or a payload')
        reader = self.contract.base.read_file
        def changed_after_read(name, fd, **kwargs):
            raw = reader(name, fd, **kwargs)
            script.write_bytes(original + b'# concurrent change\n')
            return raw
        with patch.object(self.contract.base, 'read_file', side_effect=changed_after_read):
            changed = self.contract.inspect_scripts(value, str(self.source), requested)[0]
        self.assertEqual((changed['status'], changed['reason']), ('unverified', 'script_changed'))
        script.write_bytes(original)
        candidates = self.contract.selection_candidates(value, str(self.source))
        requested = {row['id']: row['observation_id'] for row in candidates}
        for text, expected in [('#!/bin/bash\n# fixture café\nif true; then\n sudo fixture-tool\nfi\n', 'script_format_unsupported'),
                               ('#!/bin/bash\nif true; then\n sudo fixture-tool\nfi\n', 'script_dynamic_or_dependency'),
                               ('#!/bin/sh\n' + '# safe\n' * 1400, 'script_limit')]:
            script.write_text(text)
            current = self.contract.selection_candidates(value, str(self.source))
            result = self.contract.inspect_scripts(value, str(self.source), {r['id']: r['observation_id'] for r in current})
            self.assertEqual(result[0]['status'], 'unsupported')
            self.assertEqual(result[0]['reason'], expected)
            self.assertEqual(self.contract.inspect_scripts(value, str(self.source), requested)[0]['reason'], 'script_changed')
        script.write_bytes(original)
        for unsafe in ['link', 'hardlink', 'permissions']:
            script.unlink(missing_ok=True)
            target = self.source / ('target-' + unsafe); target.write_bytes(original); target.chmod(0o700)
            if unsafe == 'link': script.symlink_to(target)
            elif unsafe == 'hardlink': os.link(target, script)
            else: script.write_bytes(original); script.chmod(0o777)
            self.assertNotEqual(self.contract.inspect_scripts(value, str(self.source), requested)[0]['status'], 'qualified')
        self.assertFalse(any(self.home.iterdir()))

    def test_script_inspection_batch_rechecks_all_files_before_return(self):
        c = self.contract
        directory = self.source / 'Scripts'; directory.mkdir(mode=0o700)
        paths = ['Scripts/first.sh', 'Scripts/second.sh']
        files = [self.source / path for path in paths]
        original = b'#!/bin/sh\n/usr/bin/uname -s\n'
        (self.source / '.zshrc').write_text(''.join(
            f"alias file{index}='$HOME/{path}'\n" for index, path in enumerate(paths)))
        for policy in (None, c.OPAQUE_POLICY, c.FILE_POLICY):
            for change in ('content', 'mode', 'missing', 'symlink', 'observation-error'):
                with self.subTest(policy=policy, change=change):
                    for path in files:
                        path.unlink(missing_ok=True)
                        path.write_bytes(original); path.chmod(0o700)
                    value = c.capture(str(self.source))
                    candidates = c.selection_candidates(value, str(self.source), policy=policy)
                    requested = {row['id']: row['observation_id'] for row in candidates}
                    reader, observer = c.base.read_file, c.sources.dependency_states
                    finished = False
                    def read(name, fd, **kwargs):
                        nonlocal finished
                        raw = reader(name, fd, **kwargs)
                        if name == files[1].name:
                            finished = True
                            if change == 'content': files[0].write_bytes(original + b'# changed later\n')
                            elif change == 'mode': files[0].chmod(0o600)
                            elif change == 'missing': files[0].unlink()
                            elif change == 'symlink':
                                files[0].unlink(); files[0].symlink_to(files[1])
                        return raw
                    def observe(*args, **kwargs):
                        if finished and change == 'observation-error':
                            raise OSError('fixture observation unavailable')
                        return observer(*args, **kwargs)
                    with patch.object(c.base, 'read_file', side_effect=read), patch.object(c.sources, 'dependency_states', side_effect=observe):
                        results = c.inspect_scripts(value, str(self.source), requested, policy)
                    self.assertTrue(finished)
                    self.assertEqual([row['id'] for row in results], list(requested))
                    self.assertEqual(results[0]['status'], 'unverified')
                    if change == 'observation-error':
                        self.assertTrue(all(row['reason'] == 'script_observation_failed' and row['status'] == 'unverified' for row in results))
                    else:
                        self.assertEqual(results[0]['reason'], 'script_changed')
                        self.assertEqual(results[1]['status'], 'qualified')
                    self.assertEqual(value['scripts'], [], 'Inspection must not grant consent or publish payloads')
        self.assertFalse(any(self.home.iterdir()))

    def test_dependency_reasons_are_per_alias_and_fail_closed(self):
        (self.source / '.zshrc').write_text("alias editor='fixture-editor .'\nalias folder='cd ~/missing-folder'\nalias unknown='echo relative/path'\n")
        value = self.contract.capture(str(self.source))
        shutil.copy2(self.source / '.zshrc', self.home / '.zshrc')
        with patch.object(self.contract, 'tool_state', side_effect=lambda command: ('ready', 'builtin') if command in self.contract.BUILTINS else ('unverified', None)):
            self.assertEqual(self.contract.plan(value, str(self.home))['reason'], 'tool_prerequisite')
            for name, reason in [('editor', 'tool_observation_prerequisite'), ('folder', 'directory_missing_prerequisite'), ('unknown', 'operand_unsupported_prerequisite')]:
                selected = self.contract.select(value, {name})
                self.assertEqual(self.contract.dependency_reason(selected, str(self.home)), reason)
                self.assertFalse(self.contract.plan(selected, str(self.home))['writes'])
                self.assertEqual(self.contract.plan(selected, str(self.home))['rows'][0][1], 'unverified')
        selected = self.contract.select(value, {'editor'})
        with patch.object(self.contract, 'tool_state', return_value=('missing', None)):
            self.assertEqual(self.contract.dependency_reason(selected, str(self.home)), 'tool_missing_prerequisite')
        folder = self.home / 'missing-folder'; folder.mkdir(mode=0o700)
        selected = self.contract.select(value, {'folder'})
        self.assertIsNone(self.contract.dependency_reason(selected, str(self.home)))
        self.assertEqual(self.contract.plan(selected, str(self.home))['rows'][0][1], 'matching')
        folder.chmod(0o777)
        self.assertEqual(self.contract.dependency_reason(selected, str(self.home)), 'directory_observation_prerequisite')

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.source, self.home = self.root / 'source', self.root / 'target'
        self.source.mkdir(mode=0o700); self.home.mkdir(mode=0o700)
        self.contract = shell_aliases.recovery_contract()
        self.environment = patch.dict(os.environ, {'HOME': str(self.home)}, clear=False)
        self.environment.start(); self.addCleanup(self.environment.stop)
        os.environ.pop('ZDOTDIR', None)

    def fixture(self, script=False):
        (self.source / '.config/zsh').mkdir(parents=True)
        (self.source / '.zshrc').write_text('source "$HOME/.config/zsh/aliases"\n')
        text = "alias infra='git status'\n"
        if script:
            (self.source / '.local/bin').mkdir(parents=True)
            target = self.source / '.local/bin/adns'
            target.write_text('#!/bin/sh\n/usr/bin/uname -s\n'); target.chmod(0o700)
            text += "alias adns='$HOME/.local/bin/adns'\n"
        (self.source / '.config/zsh/aliases').write_text(text)
        return self.contract.capture(str(self.source))

    def test_clean_root_and_sourced_structure_noop(self):
        (self.source / '.zshrc').write_text("alias ll='ls -la'\n")
        value = self.contract.capture(str(self.source))
        self.assertTrue(self.contract.publish(value, str(self.home)))
        self.assertFalse(self.contract.publish(value, str(self.home)))
        (self.home / '.zshrc').unlink(); (self.source / '.zshrc').unlink()
        value = self.fixture()
        self.assertTrue(self.contract.publish(value, str(self.home)))
        for path in ('.config', '.config/zsh'):
            self.assertEqual(stat.S_IMODE((self.home / path).stat().st_mode), 0o700)
        for path in ('.zshrc', '.config/zsh/aliases'):
            self.assertEqual((self.source / path).read_bytes(), (self.home / path).read_bytes())
            self.assertEqual(stat.S_IMODE((self.home / path).stat().st_mode), 0o600)
        self.assertTrue(all(state == 'matching' for _, state, _ in self.contract.assess(value, str(self.home))))
        stamps = {p: shell_aliases.stamp((self.home / p).stat()) for p in ('.zshrc', '.config/zsh/aliases')}
        self.assertFalse(self.contract.publish(value, str(self.home)))
        self.assertEqual(stamps, {p: shell_aliases.stamp((self.home / p).stat()) for p in stamps})

    def test_existing_source_prefix_and_missing_parent_repair(self):
        value = self.fixture()
        target = self.home / '.zshrc'
        target.write_text('# preserve comment\nsource "$HOME/.config/zsh/aliases"\n')
        original = target.read_bytes()
        self.assertTrue(self.contract.publish(value, str(self.home)))
        self.assertEqual(target.read_bytes(), original)
        leaf = self.home / '.config/zsh/aliases'
        leaf.write_text("# keep metadata\nalias existing='pwd'\n"); leaf.chmod(0o640)
        before = leaf.read_bytes()
        self.assertTrue(self.contract.publish(value, str(self.home)))
        self.assertEqual(leaf.read_bytes(), before + b"alias infra='git status'\n")
        self.assertEqual(stat.S_IMODE(leaf.stat().st_mode), 0o640)

    def test_script_explicit_capture_restore_consent_and_independent_evidence(self):
        value = self.fixture(script=True)
        candidate = self.contract.script_candidates(value, str(self.source))[0]
        with patch.object(self.contract.base, 'read_file', side_effect=AssertionError('no unauthorized script read')):
            self.assertEqual(self.contract.script_candidates(value, str(self.source)), [candidate])
        self.assertFalse(value['scripts'])
        observed = self.contract.sources.dependency_states(value, str(self.source))
        with self.assertRaises(ValueError): self.contract.authorize_capture(value, str(self.source), [candidate['id']], {})
        value = self.contract.authorize_capture(value, str(self.source), [candidate['id']], observed)
        self.assertNotIn(str(self.source), json.dumps(value))
        self.assertEqual(self.contract.restore_scripts(value, str(self.home)), [candidate])
        with self.assertRaises(ValueError): self.contract.publish(value, str(self.home))
        self.assertFalse(list(self.home.iterdir()))
        published = []
        publish_content = self.contract.sources.publish_content
        def ordered_publish(home, path, content, validate, mode, **kwargs):
            self.assertTrue((self.home / path).parent.is_dir(), 'Required directories precede file publication')
            if path in ('.config/zsh/aliases', '.zshrc'):
                self.assertEqual((self.home / candidate['path']).read_bytes(), (self.source / candidate['path']).read_bytes(),
                                 'Executable dependency precedes alias/source activation')
            if path == '.zshrc':
                self.assertEqual((self.home / '.config/zsh/aliases').read_bytes(), (self.source / '.config/zsh/aliases').read_bytes())
            result = publish_content(home, path, content, validate, mode, **kwargs)
            published.append(path)
            return result
        with patch.object(self.contract.sources, 'publish_content', side_effect=ordered_publish):
            self.assertTrue(self.contract.publish(value, str(self.home), approvals=[candidate['id']]))
        self.assertEqual(published, [candidate['path'], '.config/zsh/aliases', '.zshrc'])
        self.assertEqual((self.home / candidate['path']).read_bytes(), (self.source / candidate['path']).read_bytes())
        self.assertEqual(stat.S_IMODE((self.home / candidate['path']).stat().st_mode), 0o700)
        self.assertFalse(self.contract.publish(value, str(self.home)))
        script = self.home / candidate['path']; script.write_text('#!/bin/sh\n/bin/date\n')
        self.assertEqual([(row['name'], state) for row, state, _ in self.contract.assess(value, str(self.home))], [('infra', 'matching'), ('adns', 'differing')])
        with self.assertRaises(ValueError): self.contract.publish(value, str(self.home))
        self.assertEqual(script.read_text(), '#!/bin/sh\n/bin/date\n')
        script.write_bytes((self.source / candidate['path']).read_bytes())
        leaf = self.home / '.config/zsh/aliases'
        leaf.write_text(leaf.read_text().replace("alias adns='$HOME/.local/bin/adns'", "alias adns='pwd'"))
        self.assertEqual([(row['name'], state) for row, state, _ in self.contract.assess(value, str(self.home))],
                         [('infra', 'matching'), ('adns', 'differing')],
                         'Matching script bytes cannot conceal a conflicting alias declaration')
        self.assertEqual(script.read_bytes(), (self.source / candidate['path']).read_bytes())

    def test_missing_unsafe_sensitive_and_dynamic_dependencies_fail_closed(self):
        value = self.fixture(script=True)
        self.assertEqual(self.contract.plan(value, str(self.home))['reason'], 'dependency_prerequisite')
        source = self.source / '.local/bin/adns'
        key = self.contract.script_id('.local/bin/adns')
        for text in ('#!/bin/sh\necho secret_value\n', '#!/bin/sh\nsource "$HOME/other"\n', '#!/bin/sh\n/bin/date; touch marker\n', '#!/usr/bin/python3\nprint(1)\n'):
            source.write_text(text)
            with self.assertRaises(ValueError): self.contract.authorize_capture(value, str(self.source), [key])
        source.write_text('#!/bin/sh\n/bin/date\n'); source.chmod(0o777)
        with self.assertRaises(ValueError): self.contract.authorize_capture(value, str(self.source), [key])
        source.chmod(0o700)
        value = self.contract.authorize_capture(value, str(self.source), [key])
        (self.home / '.local').symlink_to(self.source / '.local')
        with self.assertRaises(ValueError): self.contract.publish(value, str(self.home), approvals=[key])
        self.assertFalse((self.home / '.zshrc').exists())

    def test_managed_checkout_route_and_directory_names(self):
        value = self.fixture()
        (self.source / '.config/.git').mkdir()
        managed = self.contract.capture(str(self.source))
        self.assertTrue(any(item['managed'] for item in managed['layout']))
        self.assertEqual(self.contract.plan(managed, str(self.home))['reason'], 'managed_source_prerequisite')
        shutil.copytree(self.source / '.config', self.home / '.config')
        shutil.copyfile(self.source / '.zshrc', self.home / '.zshrc')
        self.assertFalse(self.contract.publish(managed, str(self.home)))
        (self.home / '.config/zsh/aliases').write_text('# externally restored but incomplete\n')
        with self.assertRaises(ValueError): self.contract.publish(managed, str(self.home))
        self.assertEqual((self.home / '.config/zsh/aliases').read_text(), '# externally restored but incomplete\n')
        # A directory name is not ownership evidence.
        (self.source / '.dotfiles').mkdir()
        (self.source / '.dotfiles/aliases').write_text("alias infra='git status'\n")
        (self.source / '.zshrc').write_text('source "$HOME/.dotfiles/aliases"\n')
        named = self.contract.capture(str(self.source))
        self.assertFalse(any(item['managed'] for item in named['layout']))
        target = self.root / 'named-target'; target.mkdir(mode=0o700)
        self.assertTrue(self.contract.publish(named, str(target)))
        self.assertFalse(self.contract.publish(named, str(target)))

    def test_conflicts_dormant_sources_and_order(self):
        value = self.fixture()
        (self.home / '.zshrc').write_text("alias infra='false'\n")
        with self.assertRaises(ValueError): self.contract.publish(value, str(self.home))
        (self.home / '.zshrc').write_text('# existing\n')
        (self.home / '.config/zsh').mkdir(parents=True)
        leaf = self.home / '.config/zsh/aliases'
        leaf.write_text("alias infra='git status'\neval unsafe\n")
        with self.assertRaises(ValueError): self.contract.publish(value, str(self.home))
        self.assertEqual((self.home / '.zshrc').read_text(), '# existing\n')
        leaf.write_text("alias infra='git status'\n")
        self.assertTrue(self.contract.publish(value, str(self.home)))
        # Omitting an unqualified initialization source is not a closed slice.
        (self.source / '.zshrc').write_text('source dynamic\nalias independent="git status"\n')
        dynamic = self.contract.capture(str(self.source))
        self.assertFalse(dynamic['layout'][0]['closed'])
        target = self.root / 'dynamic-target'; target.mkdir(mode=0o700)
        with self.assertRaises(ValueError): self.contract.publish(dynamic, str(target))
        # Conflicting required relationship order cannot be solved by append.
        (self.source / '.zshrc').write_text("alias before='pwd'\nsource \"$HOME/.config/zsh/aliases\"\n")
        value = self.contract.capture(str(self.source))
        with self.assertRaises(ValueError): self.contract.publish(value, str(self.home))

    def test_stale_and_interrupted_publication_retains_evidence(self):
        value = self.fixture()
        evidence = self.contract.evidence(value, str(self.home))
        (self.home / '.zshrc').write_text('# competing edit\n')
        with self.assertRaises(ValueError): self.contract.publish(value, str(self.home), evidence)
        self.assertFalse((self.home / '.config').exists())
        with patch.object(self.contract.sources, 'rename', side_effect=OSError('fixture interruption')):
            with self.assertRaises(self.contract.base.PublicationUncertain): self.contract.publish(value, str(self.home))
        self.assertTrue(list(self.home.rglob('.macseed-shell-pending-*')))
        with self.assertRaises(ValueError): self.contract.publish(value, str(self.home))
        self.assertEqual((self.home / '.zshrc').read_text(), '# competing edit\n')

        # A competing file arriving with a newly created parent is preserved.
        target = self.root / 'racing-target'; target.mkdir(mode=0o700)
        mkdir = os.mkdir
        def competing_file(path, *args, **kwargs):
            result = mkdir(path, *args, **kwargs)
            if path == 'zsh':
                directory = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=kwargs['dir_fd'])
                try:
                    fd = os.open('aliases', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=directory)
                    with os.fdopen(fd, 'wb') as stream: stream.write(b'# competing user file\n')
                finally:
                    os.close(directory)
            return result
        with patch.object(self.contract.os, 'mkdir', side_effect=competing_file):
            with self.assertRaises(self.contract.base.PublicationUncertain): self.contract.publish(value, str(target))
        self.assertEqual((target / '.config/zsh/aliases').read_bytes(), b'# competing user file\n')
        self.assertFalse((target / '.zshrc').exists())

    def test_tool_absence_integrity_and_selection_contract(self):
        value = self.fixture(script=True)
        key = self.contract.script_id('.local/bin/adns')
        value = self.contract.authorize_capture(value, str(self.source), [key])
        selected = self.contract.select(value, ['infra'])
        self.assertFalse(selected['scripts'])
        self.assertEqual(len(selected['aliases']), 1)
        self.assertEqual(shell_aliases.snapshot(self.contract.encode(selected)), selected)
        with patch.object(self.contract, 'tool_state', return_value=('missing', None)):
            self.assertEqual(self.contract.plan(selected, str(self.home))['reason'], 'tool_prerequisite')
        changed = copy.deepcopy(value); changed['scripts'][0]['sha256'] = '0' * 64
        with self.assertRaises(ValueError): self.contract.snapshot(self.contract.encode(changed))
        changed = copy.deepcopy(value); changed['layout'][0]['entries'].append({'source': '.zshrc'})
        with self.assertRaises(ValueError): self.contract.snapshot(self.contract.encode(changed))

    def test_independent_new_root_preserves_excluded_initialization_boundary(self):
        source = self.source / '.zshrc'
        source.write_text('eval "$(unknown_initializer)"\n' + "alias ll='ls -lah'\nalias la='ls -A'\n")
        value = self.contract.capture(str(self.source))
        self.assertFalse(value['layout'][0]['closed'])
        with patch('subprocess.Popen', side_effect=AssertionError('must not execute source')):
            self.assertTrue(self.contract.publish(value, str(self.home)))
        self.assertEqual((self.home / '.zshrc').read_text(), "alias ll='ls -lah'\nalias la='ls -A'\n")
        self.assertFalse(self.contract.publish(value, str(self.home)))
        (self.home / '.zshrc').write_text('# existing target is preserved\n')
        with self.assertRaises(ValueError): self.contract.publish(value, str(self.home))
        self.assertEqual((self.home / '.zshrc').read_text(), '# existing target is preserved\n')
        (self.home / '.zshrc').unlink()
        source.write_text(source.read_text() + "alias reload='source ~/.zshrc'\n")
        value = self.contract.capture(str(self.source))
        with self.assertRaises(ValueError): self.contract.publish(value, str(self.home))
        self.assertFalse((self.home / '.zshrc').exists())

    def test_literal_wrappers_modes_consent_and_fail_closed_classification(self):
        value = self.fixture(script=True)
        script = self.source / '.local/bin/adns'
        text = '#!/bin/bash\n# Report platform version\n/usr/bin/sw_vers -productVersion\n/usr/bin/git log --oneline -5\n'
        script.write_text(text); script.chmod(0o755)
        key = self.contract.script_id('.local/bin/adns')
        self.assertTrue(self.contract.script_analysis(text)['qualified'])
        with patch('subprocess.Popen', side_effect=AssertionError('must not execute script')):
            captured = self.contract.authorize_capture(value, str(self.source), [key])
            self.assertEqual(captured['scripts'][0]['mode'], 0o755)
            with self.assertRaises(ValueError): self.contract.publish(captured, str(self.home))
            self.assertTrue(self.contract.publish(captured, str(self.home), approvals=[key]))
            self.assertFalse(self.contract.publish(captured, str(self.home)))
        self.assertEqual((self.home / '.local/bin/adns').read_text(), text)
        self.assertEqual(stat.S_IMODE((self.home / '.local/bin/adns').stat().st_mode), 0o755)
        # The old date -u profile remains accepted, despite its ambiguous short option.
        self.assertTrue(self.contract.script_valid('#!/bin/sh\n/bin/date -u\n'))
        for text in ('#!/bin/sh\n/usr/bin/sw_vers; /bin/date\n', '#!/bin/sh\n/usr/bin/python3 -c 1\n',
                     '#!/bin/sh\n/usr/bin/perl5.34 -e 1\n', '#!/bin/sh\n/usr/bin/printf secret_value\n',
                     '#!/bin/sh\n/bin/cat private.conf\n', '#!/bin/sh\n/bin/ls "$HOME/Projects"\n',
                     '#!/bin/sh\n# password=fixture\n/bin/date\n', '#!/bin/sh\n/bin/date > output\n',
                     '#!/bin/sh\nif true; then /bin/date; fi\n', '#!/bin/sh\nhelper() { /bin/date; }\n',
                     '#!/bin/sh\n/usr/bin/env bash\n', '#!/bin/sh\n/bin/date $(unknown)\n'):
            with self.subTest(case=self.contract.script_analysis(text)['reason']):
                self.assertFalse(self.contract.script_valid(text))
                script.write_text(text)
                with self.assertRaises(ValueError): self.contract.authorize_capture(value, str(self.source), [key])
        script.write_text('#!/bin/sh\n/usr/bin/sw_vers -productVersion\n')
        for mode in (0o777, 0o775, 0o4755, 0o600):
            script.chmod(mode)
            with self.assertRaises(ValueError): self.contract.authorize_capture(value, str(self.source), [key])
        script.chmod(0o755)
        os.link(script, self.source / 'hardlink')
        with self.assertRaises(ValueError): self.contract.authorize_capture(value, str(self.source), [key])

    def test_script_cannot_become_startup_or_sourced_code(self):
        value = self.fixture(script=True)
        for name in ('.zshenv', '.ZSHENV', '.zprofile', '.zshrc', '.zlogin', '.zlogout', '.profile'):
            changed = copy.deepcopy(value)
            changed['aliases'][1]['statement'] = "alias adns='$HOME/" + name + "'"
            script = dict(path=name, text='#!/bin/sh\n/bin/date\n', mode=0o755)
            script['sha256'] = hashlib.sha256(script['text'].encode()).hexdigest()
            changed['scripts'] = [script]
            with self.assertRaises(ValueError): self.contract.snapshot(self.contract.encode(changed))
        captured = self.contract.authorize_capture(value, str(self.source), [self.contract.script_id('.local/bin/adns')])
        (self.home / '.local/bin').mkdir(parents=True)
        (self.home / '.zprofile').write_text('source "$HOME/.local/bin/ADNS"\n')
        plan = self.contract.plan(captured, str(self.home))
        self.assertEqual(plan['reason'], 'script_source_activation')
        with self.assertRaises(ValueError): self.contract.publish(captured, str(self.home), approvals=[self.contract.script_id('.local/bin/adns')])
        self.assertFalse((self.home / '.local/bin/adns').exists())
        self.assertFalse((self.home / '.zshrc').exists())

    def test_managed_directory_alias_requires_real_existing_destination(self):
        (self.source / '.config/dotfiles').mkdir(parents=True)
        (self.source / '.config/dotfiles/.git').mkdir()
        (self.source / '.zshrc').write_text('source "$HOME/.config/dotfiles/aliases"\n')
        (self.source / '.config/dotfiles/aliases').write_text("alias infra='cd $HOME/Projects/infra'\n")
        (self.source / 'Projects/infra').mkdir(parents=True)
        value = self.contract.capture(str(self.source))
        self.assertEqual(self.contract.plan(value, str(self.home))['reason'], 'managed_source_prerequisite')
        # External owner/Workspace restored the source checkout and its relationship.
        shutil.copytree(self.source / '.config', self.home / '.config')
        shutil.copyfile(self.source / '.zshrc', self.home / '.zshrc')
        self.assertEqual(self.contract.plan(value, str(self.home))['reason'], 'operand_prerequisite')
        self.assertFalse((self.home / 'Projects').exists())
        (self.home / 'Projects/infra').mkdir(parents=True)
        self.assertTrue(all(state == 'matching' for _, state, _ in self.contract.assess(value, str(self.home))))
        self.assertFalse(self.contract.publish(value, str(self.home)))
        evidence = self.contract.evidence(value, str(self.home))
        (self.home / 'Projects/infra').chmod(0o777)
        self.assertNotEqual(self.contract.evidence(value, str(self.home)), evidence)
        with self.assertRaises(ValueError): self.contract.publish(value, str(self.home), expected=evidence)
        (self.home / 'Projects/infra').chmod(0o700); (self.home / 'Projects/infra').rmdir()
        (self.home / 'Projects/infra').symlink_to(self.source / 'Projects/infra')
        self.assertEqual(self.contract.plan(value, str(self.home))['reason'], 'operand_prerequisite')
        # Legacy literal quoted tilde is not reinterpreted as HOME provenance.
        alias = dict(value['aliases'][0], statement='alias infra="cd \'~/Projects/infra\'"')
        self.assertIsNone(self.contract.directory_operand(alias))



class ShellAliasTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name).resolve() / 'home'
        self.home.mkdir(mode=0o700)
        self.path = self.home / '.zshrc'
        self.raw = b"alias ll='ls -la'\nalias gs=\"git status\"\n"
        self.rows, _ = shell_aliases.classify(self.raw)
        self.value = shell_aliases.snapshot(shell_aliases.encode(self.rows))
        self.environment = patch.dict(os.environ, {'HOME': str(self.home)}, clear=False)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        os.environ.pop('ZDOTDIR', None)

    def test_static_order_quoting_comments_continuations(self):
        raw = b"# alias comment='false'\nalias ll='ls -la' # unrelated note\nalias \\\n gs=\"git status\"\nalias say='echo \"hello world\"'\n"
        rows, partial = shell_aliases.classify(raw)
        self.assertEqual([r['name'] for r in rows], ['ll', 'gs', 'say'])
        self.assertFalse(partial)
        self.assertEqual(rows[0]['statement'], "alias ll='ls -la'")
        continued, _ = shell_aliases.classify(b"alias \\\n literal='ls -la'\n")
        self.assertEqual([row['name'] for row in continued], ['literal'])
        encoded = shell_aliases.encode(rows, partial)
        self.assertEqual(shell_aliases.snapshot(encoded)['aliases'], rows)
        selected = shell_aliases.snapshot(shell_aliases.select_snapshot(encoded, ['say', 'll']))
        self.assertEqual([r['name'] for r in selected['aliases']], ['ll', 'say'])

    def test_mixed_contexts_duplicates_and_dynamic_definitions(self):
        raw = (b'source "$HOME/plugins.zsh"\neval "$(brew shellenv)"\n' + self.raw
               + b"if test -e optional; then\nalias conditional='false'\nfi\n"
               + b"helper() {\n alias nested='false'\n}\nalias ..='cd ..'\n")
        rows, partial = shell_aliases.classify(raw)
        self.assertEqual(rows, self.rows)
        self.assertTrue(partial)
        for tail in (b"alias ll='ls'\n", b"if true; then alias ll='ls'; fi\n", b'unalias ll\n'):
            self.assertEqual([r['name'] for r in shell_aliases.classify(self.raw + tail)[0]], ['gs'])
        for raw in (b"true &&\nalias conditional='ls'\n", b"false ||\nalias conditional='ls'\n",
                    b"false && # continuation\nalias conditional='ls'\n"):
            self.assertEqual(shell_aliases.classify(raw)[0], [])
        for raw in (b"[[\nalias conditional='ls'\n]]\n", b"return\nalias unreachable='ls'\n"):
            self.assertEqual(shell_aliases.classify(raw)[0], [])
        rows, _ = shell_aliases.classify(b"alias ll='ls' gs='git diff'\nalias gs='git status'\n")
        self.assertEqual(rows, [])
        for tail in (b"alias $NAME='ls'\n", b"cat <<EOF\nalias fake='ls'\nEOF\n", b"function unfinished\n", b"alias bad='unterminated\n", b"function alias { echo unsafe; }\n"):
            with self.assertRaises(shell_aliases.Invalid):
                shell_aliases.classify(self.raw + tail)
        rows, _ = shell_aliases.classify(b"alias g='git'\nalias gs='g status'\n")
        self.assertEqual([r['name'] for r in rows], ['g'])
        rows, _ = shell_aliases.classify(b"helper() { echo ok; }\nalias dependent='helper'\n" + self.raw)
        self.assertEqual(rows, self.rows)

    def test_sensitive_dynamic_and_architecture_paths_excluded(self):
        for value in ('echo $HOME', 'echo $(id)', 'echo `id`', 'curl --token value',
                      'curl --user user:credential', 'curl postgres://user:private@example.invalid',
                      '/opt/homebrew/bin/brew list', '/usr/local/bin/brew list', 'cd /Users/source/private',
                      'echo a; echo b', 'ls | head', 'echo safe ', 'cd ~anotheruser'):
            raw = self.raw + ("alias excluded='" + value + "'\n").encode()
            self.assertEqual(shell_aliases.classify(raw)[0], self.rows)
        rows, _ = shell_aliases.classify(self.raw + b"export API_TOKEN=private_fixture\n")
        self.assertEqual(rows, self.rows)
        self.assertNotIn(b'private_fixture', shell_aliases.encode(rows))

    def test_snapshot_shape_bounds_and_round_trip(self):
        self.assertEqual(shell_aliases.snapshot(shell_aliases.encode(self.rows))['aliases'], self.rows)
        for value in ({'version': 2, 'coverage': 'partial', 'aliases': self.rows},
                      {'version': True, 'coverage': 'partial', 'aliases': self.rows},
                      {'version': 1, 'coverage': 'partial', 'aliases': self.rows * 2},
                      {'version': 1, 'coverage': 'partial', 'aliases': []},
                      {'version': 1, 'coverage': 'partial', 'aliases': [{'name':'forged', 'statement':"alias x='ls'"}]}):
            with self.assertRaises(shell_aliases.Invalid):
                shell_aliases.snapshot(shell_aliases.MAGIC + json.dumps(value).encode())
        with self.assertRaises(shell_aliases.Invalid):
            shell_aliases.snapshot(shell_aliases.MAGIC + b'{"version":1,"version":1}')
        with self.assertRaises(shell_aliases.Invalid):
            shell_aliases.classify(b'#' * 65537)

    def test_matching_missing_conflict_repeat_and_no_existing_file_merge(self):
        self.assertEqual([x[1:] for x in shell_aliases.assess(self.value, str(self.home))], [('missing','create')] * 2)
        self.assertFalse(self.path.exists())
        self.assertTrue(shell_aliases.publish(self.value, str(self.home)))
        self.assertEqual(self.path.read_bytes(), self.raw)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        before = self.path.stat().st_mtime_ns
        self.assertFalse(shell_aliases.publish(self.value, str(self.home)))
        self.assertEqual(self.path.stat().st_mtime_ns, before)
        self.path.write_bytes(b"alias ll='ls'\n")
        before = self.path.read_bytes()
        self.assertEqual([x[1:] for x in shell_aliases.assess(self.value, str(self.home))], [('differing','preserve'),('missing','preserve')])
        with self.assertRaises(shell_aliases.Invalid):
            shell_aliases.publish(self.value, str(self.home))
        self.assertEqual(self.path.read_bytes(), before)
        self.path.write_bytes(b"if true; then alias ll='ls -la'; fi\n")
        self.assertEqual(shell_aliases.assess(self.value, str(self.home))[0][1], 'unverified')

    def test_home_file_links_modes_acl_startup_and_no_clobber(self):
        self.path.symlink_to(self.home / 'absent')
        self.assertTrue(all(s == 'unverified' for _, s, _ in shell_aliases.assess(self.value, str(self.home))))
        with self.assertRaises(shell_aliases.Invalid): shell_aliases.publish(self.value, str(self.home))
        self.path.unlink(); self.path.write_bytes(self.raw); self.path.chmod(0o666)
        self.assertTrue(all(s == 'unverified' for _, s, _ in shell_aliases.assess(self.value, str(self.home))))
        self.path.chmod(0o600)
        os.chflags(self.path, shell_aliases.USER_READ_FLAGS)
        try:
            self.assertTrue(all(s == 'matching' for _, s, _ in shell_aliases.assess(self.value, str(self.home))))
            self.assertFalse(shell_aliases.publish(self.value, str(self.home)))
            self.assertEqual(self.path.stat().st_flags, shell_aliases.USER_READ_FLAGS)
            with self.assertRaises(shell_aliases.Invalid):
                shell_aliases.read_file(self.path, private=True)
            os.chflags(self.path, stat.UF_IMMUTABLE)
            self.assertTrue(all(s == 'unverified' for _, s, _ in shell_aliases.assess(self.value, str(self.home))))
        finally:
            os.chflags(self.path, 0)
        with patch.object(shell_aliases.os, 'getuid', return_value=os.getuid() + 1):
            self.assertTrue(all(s == 'unverified' for _, s, _ in shell_aliases.assess(self.value, str(self.home))))
        subprocess.run(['/bin/chmod', '+a', 'everyone allow read', str(self.path)], check=True)
        self.assertTrue(all(s == 'unverified' for _, s, _ in shell_aliases.assess(self.value, str(self.home))))
        subprocess.run(['/bin/chmod', '-N', str(self.path)], check=True)
        link = self.home.parent / 'linked-home'; link.symlink_to(self.home)
        self.assertTrue(all(s == 'unverified' for _, s, _ in shell_aliases.assess(self.value, str(link))))
        (self.home / '.zshenv').write_text('ZDOTDIR=elsewhere\n')
        self.assertTrue(all(s == 'unverified' for _, s, _ in shell_aliases.assess(self.value, str(self.home))))
        (self.home / '.zshenv').unlink()
        with patch.dict(os.environ, ZDOTDIR='/other'):
            self.assertTrue(all(s == 'unverified' for _, s, _ in shell_aliases.assess(self.value, str(self.home))))
        (self.home / '.zshrc.zwc').touch()
        self.assertTrue(all(s == 'unverified' for _, s, _ in shell_aliases.assess(self.value, str(self.home))))
        (self.home / '.zshrc.zwc').unlink(); self.path.unlink()
        def competing_target(*args, **kwargs):
            self.path.write_bytes(b'preserve competing writer\n')
            raise FileExistsError()
        with patch.object(shell_aliases.os, 'link', side_effect=competing_target):
            with self.assertRaises(FileExistsError): shell_aliases.publish(self.value, str(self.home))
        self.assertEqual(self.path.read_bytes(), b'preserve competing writer\n')
        self.assertFalse(list(self.home.glob('.macseed-zsh-*')))


class ShellSourceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name).resolve() / 'home'
        self.home.mkdir(mode=0o700)
        self.sources = shell_aliases.source_contract()
        self.env = patch.dict(os.environ, {'HOME': str(self.home)})
        self.env.start(); self.addCleanup(self.env.stop)
        os.environ.pop('ZDOTDIR', None)
        (self.home / '.config').mkdir()
        self.start = self.home / '.zshrc'
        self.target = self.home / '.config/aliases'
        self.start.write_text('source "$HOME/.config/aliases"\n')
        self.raw = b"# preserve user comments\nalias ll='ls -la'\nalias gs='git status'\n"
        self.target.write_bytes(self.raw)
        self.value = self.sources.capture(str(self.home))

    def states(self, value=None):
        return [(state, policy) for _, state, policy in self.sources.assess(value or self.value, str(self.home))]

    def test_extended_grammar_preserves_inert_bytes_and_legacy_boundary(self):
        script = self.home / '.config/helper.sh'
        script.write_text('#!/bin/sh\ntouch "$HOME/must-not-run"\n'); script.chmod(0o700)
        (self.home / '.config/Local Tools').mkdir()
        spaced = self.home / '.config/Local Tools/helper.sh'
        spaced.write_bytes(script.read_bytes()); spaced.chmod(0o700)
        additions = (b'alias c.="code ."\n'
                     b'alias reload_local="source ~/.zshrc"\n'
                     b"alias run_local='$HOME/.config/helper.sh'\n"
                     b'alias quoted_local=\'"${HOME}/.config/Local Tools/helper.sh" --check\'\n'
                     b"alias dot_local='. ~/.zshrc'\n")
        self.target.write_bytes(self.raw + additions)
        value = self.sources.capture(str(self.home))
        self.assertEqual([r['name'] for r in value['aliases']],
                         ['ll', 'gs', 'c.', 'reload_local', 'run_local', 'quoted_local', 'dot_local'])
        self.assertEqual(('\n'.join(r['statement'] for r in value['aliases'][2:]) + '\n').encode(), additions)
        self.assertTrue(all(r['chain'] == ['.zshrc', '.config/aliases'] for r in value['aliases']))
        self.assertEqual([r['order'] for r in value['aliases']], list(range(1, 8)))
        self.assertEqual(self.sources.snapshot(self.sources.encode(value)), value)
        self.assertEqual(set(self.sources.observe(str(self.home))['files']), set(self.sources.STARTUP) | {'.config/aliases'})
        for row in value['aliases'][2:]:
            if row['name'] == 'dot_local':
                # The original grammar already accepted '.', without v2 dependency qualification.
                self.assertIsNotNone(shell_aliases.declaration(row['statement']))
                continue
            with self.assertRaises(ValueError):
                shell_aliases.snapshot(shell_aliases.encode([{'name': row['name'], 'statement': row['statement']}]))
        self.target.write_bytes(self.raw)
        self.assertTrue(self.sources.publish(value, str(self.home)))
        self.assertEqual(self.target.read_bytes(), self.raw + additions)
        self.assertFalse(self.sources.publish(value, str(self.home)))
        self.assertFalse((self.home / 'must-not-run').exists())
        self.assertEqual(script.read_text(), '#!/bin/sh\ntouch "$HOME/must-not-run"\n')
        self.assertIsNone(self.sources.reference('$HOME/.config/Local Tools/helper.sh', str(self.home)))
        self.assertEqual(self.sources.reference('"$HOME/.config/Local Tools/helper.sh"', str(self.home)),
                         '.config/Local Tools/helper.sh')

        for statement in ("alias bad='$HOME/../escape'", "alias bad='${HOME}/.git/hook'",
                          "alias bad='$OTHER/script.sh'", "alias bad='${HOME:-/tmp}/script.sh'",
                          'alias bad="$HOME/.config/helper.sh"', "alias bad='$(touch marker)'",
                          "alias bad='`touch marker`'", "alias bad='source ~/missing; echo bad'",
                          "alias bad='source /Users/source/private'", "alias bad='source helper.sh'",
                          "alias bad='source $HOME/.config/helper.sh extra'", "alias bad='echo token=value'",
                          "alias bad='/usr/bin/../../private/script'", 'alias bad=\'"~/helper.sh"\'',
                          "alias bad='~other/helper.sh'", "alias bad='${HOME}/secret/script.sh'"):
            with self.subTest(statement=statement):
                self.assertIsNone(shell_aliases.declaration(statement, extended=True))
        for statement in ("alias literal='echo \"~/literal\"'", "alias legacy='. \"~/literal\"'"):
            old = shell_aliases.declaration(statement)
            self.assertIsNotNone(old)
            saved = dict(version=2, coverage='partial', roots=list(self.sources.STARTUP),
                         aliases=[dict(old[0], source='.zshrc', chain=['.zshrc'], order=1)])
            self.assertEqual(self.sources.snapshot(self.sources.encode(saved)), saved)
            self.assertEqual(self.sources.dependencies(saved), {})
        for tail in (b'alias c.="pwd"\n', b'if true; then alias c.="pwd"; fi\n', b'unalias c.\n'):
            self.target.write_bytes(self.raw + additions + tail)
            self.assertNotIn('c.', [r['name'] for r in self.sources.capture(str(self.home))['aliases']])
        self.target.write_bytes(self.raw + b"function helper. { :; }\nalias dependent='helper.'\n")
        self.assertNotIn('dependent', [r['name'] for r in self.sources.capture(str(self.home))['aliases']])
        self.start.write_text('alias reload_local="source ~/.zshrc"\n')
        self_reference = self.sources.capture(str(self.home))
        self.start.unlink()
        self.assertEqual(self.states(self_reference), [('missing', 'create')])
        self.assertTrue(self.sources.publish(self_reference, str(self.home)))
        self.assertFalse(self.sources.publish(self_reference, str(self.home)))

    def test_alias_dependency_metadata_and_freshness(self):
        (self.home / '.config/runtime').mkdir()
        script = self.home / '.config/runtime/helper.sh'
        script.write_text('#!/bin/sh\nexit 99\n'); script.chmod(0o700)
        self.target.write_text("alias run_local='$HOME/.config/runtime/helper.sh'\n")
        value = self.sources.capture(str(self.home))
        before = self.sources.evidence(value, str(self.home))
        script.write_text('#!/bin/sh\nexit 98\n')
        self.assertNotEqual(self.sources.evidence(value, str(self.home)), before)
        self.target.write_text('# retain\n')
        before = self.sources.evidence(value, str(self.home))
        script.chmod(0o600)
        self.assertEqual(self.states(value), [('missing', 'preserve')])
        with self.assertRaises(ValueError): self.sources.publish(value, str(self.home), before)
        self.assertEqual(self.target.read_text(), '# retain\n')
        script.chmod(0o700)
        managed = script.parent / '.git'
        managed.mkdir()
        for kind in ('symlink', 'hardlink', 'mode', 'flags', 'acl', 'absent'):
            with self.subTest(kind=kind):
                payload = script.read_bytes()
                if kind == 'symlink':
                    script.unlink(); script.symlink_to(self.home / '.zshrc')
                elif kind == 'hardlink': os.link(script, self.home / 'linked')
                elif kind == 'mode': script.chmod(0o722)
                elif kind == 'flags': os.chflags(script, stat.UF_IMMUTABLE)
                elif kind == 'acl': subprocess.run(['/bin/chmod', '+a', 'everyone allow write', str(script)], check=True)
                else: script.unlink()
                self.assertEqual(self.states(value), [('missing', 'preserve')])
                with self.assertRaises(ValueError): self.sources.publish(value, str(self.home))
                self.assertEqual(self.target.read_text(), '# retain\n')
                if kind == 'hardlink': (self.home / 'linked').unlink()
                if kind == 'flags': os.chflags(script, 0)
                if kind == 'acl': subprocess.run(['/bin/chmod', '-N', str(script)], check=True)
                if script.exists() or script.is_symlink(): script.unlink()
                script.write_bytes(payload); script.chmod(0o700)
        managed.rmdir()
        for marker in ('.git', '.chezmoiroot'):
            before = self.sources.evidence(value, str(self.home))
            managed = script.parent / marker; managed.mkdir()
            self.assertEqual(self.sources.dependency_states(value, str(self.home))['.config/runtime/helper.sh'][0], 'ready')
            self.assertEqual(self.states(value), [('missing', 'add')])
            with self.assertRaises(ValueError): self.sources.publish(value, str(self.home), before)
            observed = self.sources.evidence(value, str(self.home))
            (managed / 'unrelated-manager-state').write_text('fixture\n')
            self.assertEqual(self.sources.evidence(value, str(self.home)), observed)
            (managed / 'unrelated-manager-state').unlink()
            script_bytes, script_stamp = script.read_bytes(), shell_aliases.stamp(script.stat())
            original_read = self.sources.base.read_file
            def no_script_read(name, *args, **kwargs):
                self.assertNotEqual(Path(name).name, 'helper.sh')
                return original_read(name, *args, **kwargs)
            with patch.object(self.sources.base, 'read_file', side_effect=no_script_read):
                self.assertTrue(self.sources.publish(value, str(self.home)))
                self.assertFalse(self.sources.publish(value, str(self.home)))
            self.assertEqual(script.read_bytes(), script_bytes)
            self.assertEqual(shell_aliases.stamp(script.stat()), script_stamp)
            self.target.write_text('# retain\n'); managed.rmdir()
        self.assertTrue(self.sources.publish(value, str(self.home)))
        self.target.write_text('# retain again\n')
        rename = self.sources.rename
        def dependency_writer(a, source, b, destination, flag):
            result = rename(a, source, b, destination, flag)
            if flag == 2: script.write_text('# concurrent dependency edit\n')
            return result
        with patch.object(self.sources, 'rename', side_effect=dependency_writer):
            with self.assertRaises(self.sources.base.PublicationUncertain):
                self.sources.publish(value, str(self.home))
        self.assertIn(b'alias run_local=', self.target.read_bytes())
        self.assertEqual(script.read_text(), '# concurrent dependency edit\n')
        script.unlink()
        self.assertEqual(self.states(value), [('matching', 'preserve')])
        self.assertEqual(self.sources.dependency_states(value, str(self.home))['.config/runtime/helper.sh'][0], 'missing')
        self.assertFalse(self.sources.publish(value, str(self.home)))

    def test_managed_absolute_sources_are_read_only_portable_evidence(self):
        folder = self.home / '.config/Managed Sources'; folder.mkdir()
        (folder / '.git').mkdir()
        source = folder / 'aliases'
        source.write_text("alias sourced_item='git status'\n")
        original = source.read_bytes()
        prefix = "alias local_item='pwd'\n"
        relationship = f'source "{source}"\n'
        self.start.write_text(prefix + 'eval "$(touch $HOME/must-not-run)"\n' + relationship)
        value = self.sources.capture(str(self.home))
        self.assertEqual([r['name'] for r in value['aliases']], ['local_item', 'sourced_item'])
        self.assertEqual(value['aliases'][1]['chain'], ['.zshrc', '.config/Managed Sources/aliases'])
        self.assertNotIn(str(self.home).encode(), self.sources.encode(value))
        self.assertFalse(self.sources.observe(str(self.home))['writable'])
        self.assertEqual(self.states(value), [('matching', 'preserve')] * 2)
        source.write_text('# retain managed source\n')
        self.start.write_text(prefix + relationship)
        self.assertTrue(self.sources.observe(str(self.home))['writable'])
        self.assertEqual(self.states(value)[1], ('missing', 'preserve'))
        with self.assertRaises(ValueError): self.sources.publish(value, str(self.home))
        self.assertEqual(source.read_text(), '# retain managed source\n')
        source.write_bytes(original)
        self.assertFalse(self.sources.publish(value, str(self.home)))
        self.assertEqual(source.read_bytes(), original)
        source.unlink()
        self.assertEqual(self.states(value)[1], ('missing', 'preserve'))
        with self.assertRaises(ValueError): self.sources.publish(value, str(self.home))
        self.assertFalse(source.exists())
        source.write_bytes(original)
        self.assertFalse((self.home / 'must-not-run').exists())
        for path in (str(self.home) + '-other/aliases', str(self.home) + '/../aliases', '/other/aliases'):
            self.assertIsNone(self.sources.reference('"' + path + '"', str(self.home)))
        self.assertIsNone(self.sources.reference(str(source), str(self.home)))  # Spaces require quotes.
        # A target user's existing HOME-relative relationship proves the same
        # portable chain; the saved source statement is never rewritten/installed.
        other = self.home.parent / 'other-home'; other.mkdir()
        (other / '.config/Managed Sources').mkdir(parents=True)
        (other / '.config/Managed Sources/.git').mkdir()
        (other / '.config/Managed Sources/aliases').write_bytes(original)
        (other / '.zshrc').write_text(prefix + 'source "$HOME/.config/Managed Sources/aliases"\n')
        self.assertTrue(all(state == 'matching' for _, state, _ in self.sources.assess(value, str(other))))
        source.unlink(); source.symlink_to(other / '.config/Managed Sources/aliases')
        self.assertEqual(self.states(value)[1], ('unverified', 'preserve'))

    def test_source_order_nested_subset_and_schema(self):
        (self.home / '.config/Nested Sources').mkdir()
        nested = self.home / '.config/Nested Sources/nested'
        nested.write_text("alias last='pwd'\n")
        self.target.write_bytes(self.raw + b'. "${HOME}/.config/Nested Sources/nested"\n')
        self.start.write_text("alias first='date'\nsource \"$HOME/.config/aliases\"\n")
        value = self.sources.capture(str(self.home))
        self.assertEqual([r['name'] for r in value['aliases']], ['first', 'll', 'gs', 'last'])
        self.assertEqual(value['aliases'][-1]['chain'], ['.zshrc', '.config/aliases', '.config/Nested Sources/nested'])
        raw = self.sources.encode(value)
        self.assertNotIn(str(self.home).encode(), raw)
        selected = shell_aliases.snapshot(shell_aliases.select_snapshot(raw, ['last', 'first']))
        self.assertEqual([r['name'] for r in selected['aliases']], ['first', 'last'])
        for field, bad in [('source', '../escape'), ('chain', ['.zshrc', '.zshrc']), ('order', True)]:
            changed = copy.deepcopy(value); changed['aliases'][0][field] = bad
            with self.assertRaises(ValueError): shell_aliases.snapshot(self.sources.encode(changed))
        for word in ('optional.zsh', "'~/aliases'", '/Users/source/aliases', '$OTHER/aliases', '$HOME/../aliases', '$(unsafe)'):
            self.assertIsNone(self.sources.reference(word, str(self.home)))

    def test_startup_order_and_qualified_zdotdir(self):
        (self.home / '.zprofile').write_text("alias profile='pwd'\n")
        (self.home / '.zlogin').write_text("alias login='date'\n")
        self.assertEqual([r['name'] for r in self.sources.capture(str(self.home))['aliases']], ['profile', 'll', 'gs', 'login'])
        zdir = self.home / '.config/zsh'; zdir.mkdir()
        (zdir / '.zshrc').write_text("alias alternate='ls'\n")
        with patch.dict(os.environ, ZDOTDIR=str(zdir)):
            value = self.sources.capture(str(self.home))
            self.assertEqual(value['aliases'][0]['source'], '.config/zsh/.zshrc')
            self.assertEqual(self.states(value), [('matching', 'preserve')])
        (self.home / '.zshenv').write_text('export ZDOTDIR="$HOME/.config/zsh"\n')
        value = self.sources.capture(str(self.home))
        self.assertEqual(value['roots'][0], '.zshenv')
        self.assertEqual(value['aliases'][0]['source'], '.config/zsh/.zshrc')
        (self.home / '.zshenv').write_text('ZDOTDIR="$(unsafe)"\n')
        with self.assertRaises(ValueError): self.sources.capture(str(self.home))

    def test_cycles_duplicates_dynamic_and_conditional_scope(self):
        self.target.write_bytes(self.raw + b'source "$HOME/.zshrc"\n')
        with self.assertRaises(ValueError): self.sources.capture(str(self.home))
        self.target.write_bytes(self.raw)
        self.start.write_text('source "$HOME/.config/aliases"\nsource "$HOME/.config/aliases"\n')
        with self.assertRaises(ValueError): self.sources.capture(str(self.home))
        self.start.write_text('source "$HOME/.config/aliases"\nalias ll="ls"\n')
        value = self.sources.capture(str(self.home))
        self.assertEqual([r['name'] for r in value['aliases']], ['gs'])
        self.assertEqual(self.states()[0], ('unverified', 'preserve'))
        self.start.write_text('if true; then\nsource "$HOME/.config/aliases"\nfi\nalias safe="pwd"\n')
        self.assertEqual([r['name'] for r in self.sources.capture(str(self.home))['aliases']], ['safe'])
        self.start.write_text('source "$UNKNOWN"\nalias safe="pwd"\n')
        self.assertEqual([r['name'] for r in self.sources.capture(str(self.home))['aliases']], ['safe'])
        self.assertTrue(all(policy == 'preserve' for _, policy in self.states()))
        self.start.write_text('source "$HOME/.config/aliases"\nunalias ll\n')
        self.assertEqual([r['name'] for r in self.sources.capture(str(self.home))['aliases']], ['gs'])
        for raw in ('source() { echo ignored; }\nsource "$HOME/.config/aliases"\n',
                    'source "$HOME/.config/aliases"\nunalias -a\n',
                    'source "$HOME/.config/aliases"\nHOME=/other\n'):
            self.start.write_text(raw)
            with self.assertRaises(ValueError): self.sources.capture(str(self.home))

    def test_safe_add_preserves_bytes_mode_metadata_and_noop(self):
        self.target.write_text("# preserve user comments\nalias ll='ls -la'\n")
        self.target.chmod(0o640)
        original = self.target.read_bytes()
        with self.sources.parent(str(self.home), '.config/aliases') as (fd, name, check):
            _, before, metadata = self.sources.mutable_file(fd, name)
        self.assertEqual(self.states(), [('matching', 'preserve'), ('missing', 'add')])
        self.assertTrue(self.sources.publish(self.value, str(self.home)))
        self.assertTrue(self.target.read_bytes().startswith(original))
        self.assertEqual(self.target.read_bytes(), original + b"alias gs='git status'\n")
        with self.sources.parent(str(self.home), '.config/aliases') as (fd, name, check):
            _, after, actual_metadata = self.sources.mutable_file(fd, name)
        self.assertEqual(stat.S_IMODE(after.st_mode), 0o640)
        self.assertEqual(after.st_gid, before.st_gid)
        self.assertEqual(actual_metadata, metadata)
        stamp = shell_aliases.stamp(self.target.stat())
        self.assertFalse(self.sources.publish(self.value, str(self.home)))
        self.assertEqual(shell_aliases.stamp(self.target.stat()), stamp)
        self.assertTrue(list(self.target.parent.glob('.macseed-shell-predecessor-*')))

    def test_missing_sources_dependencies_and_selected_conflicts(self):
        self.target.unlink()
        self.assertEqual(self.states(), [('missing', 'create')] * 2)
        self.assertTrue(self.sources.publish(self.value, str(self.home)))
        self.assertEqual(self.target.read_bytes(), b"alias ll='ls -la'\nalias gs='git status'\n")
        self.start.write_text('# relationship removed\n')
        self.assertTrue(all(state == 'unverified' for state, _ in self.states()))
        with self.assertRaises(ValueError): self.sources.publish(self.value, str(self.home))
        self.start.write_text('source "$HOME/.config/aliases"\n')
        self.target.write_text("alias ll='ls'\n")
        self.assertEqual(self.states(), [('differing', 'preserve'), ('missing', 'preserve')])
        self.target.write_text('# safe empty file\n')
        self.start.write_text('source "$HOME/.config/aliases"\nsource "$HOME/.config/unknown"\n')
        self.assertTrue(all(policy == 'preserve' for _, policy in self.states()))

    def test_owned_paths_links_flags_acl_and_private_content(self):
        self.target.write_bytes(self.raw + b'export API_TOKEN=private_fixture\n')
        self.assertNotIn(b'private_fixture', self.sources.encode(self.sources.capture(str(self.home))))
        for marker in ('# managed by dotfile tool\n', '# generated by chezmoi\n'):
            self.target.write_text(marker + self.raw.decode())
            self.assertEqual(self.states(), [('matching', 'preserve')] * 2)
            self.assertFalse(self.sources.publish(self.value, str(self.home)))
            self.target.write_text(marker + "alias ll='ls -la'\n")
            self.assertEqual(self.states()[1], ('missing', 'preserve'))
            with self.assertRaises(ValueError): self.sources.publish(self.value, str(self.home))
            self.assertEqual(self.target.read_text(), marker + "alias ll='ls -la'\n")
        self.target.write_bytes(self.raw); os.link(self.target, self.target.parent / 'linked')
        self.assertTrue(all(state == 'unverified' for state, _ in self.states()))
        (self.target.parent / 'linked').unlink(); self.target.unlink(); self.target.symlink_to('/dev/null')
        self.assertTrue(all(state == 'unverified' for state, _ in self.states()))
        self.target.unlink(); self.target.write_bytes(self.raw); os.chflags(self.target, 0x40)
        try:
            self.assertEqual(self.states(), [('matching', 'preserve')] * 2)
            self.target.write_text("alias ll='ls -la'\n")
            self.assertEqual(self.states()[1], ('missing', 'preserve'))
        finally: os.chflags(self.target, 0)
        subprocess.run(['/bin/chmod', '+a', 'everyone allow read', str(self.target)], check=True)
        self.assertTrue(all(state == 'unverified' for state, _ in self.states()))
        subprocess.run(['/bin/chmod', '-N', str(self.target)], check=True)
        (self.target.parent / '.git').mkdir()
        self.assertEqual(self.states(), [('matching', 'preserve'), ('missing', 'preserve')])
        with self.assertRaises(ValueError): self.sources.publish(self.value, str(self.home))

    def test_bounds_and_observation_freshness(self):
        original = self.sources.evidence(self.value, str(self.home))
        self.target.write_bytes(self.raw + b'# changed comment\n')
        self.assertNotEqual(self.sources.evidence(self.value, str(self.home)), original)
        for limit, value in [('MAX_FILES', 1), ('MAX_DEPTH', 1), ('MAX_TOTAL', 1)]:
            with patch.object(self.sources, limit, value):
                with self.assertRaises(ValueError): self.sources.capture(str(self.home))
        self.target.write_bytes(b'#' * (shell_aliases.MAX_BYTES + 1))
        self.assertTrue(all(state == 'unverified' for state, _ in self.states()))

        self.target.write_bytes(self.raw)
        original_read = self.sources.base.read_file
        def changed_after_read(name, directory=None, private=False, **kwargs):
            raw = original_read(name, directory, private, **kwargs)
            if name == 'aliases': self.target.write_bytes(self.raw + b'# concurrent edit\n')
            return raw
        with patch.object(self.sources.base, 'read_file', side_effect=changed_after_read):
            with self.assertRaises(ValueError): self.sources.file_state(str(self.home), '.config/aliases')

    def test_atomic_failure_and_last_gap_writer_retained(self):
        self.target.write_text('# preserved\n')
        before = self.target.read_bytes()
        with patch.object(self.sources, 'rename', side_effect=OSError('fixture publication failure')):
            with self.assertRaises(self.sources.base.PublicationUncertain):
                self.sources.publish(self.value, str(self.home))
        self.assertEqual(self.target.read_bytes(), before)
        self.assertTrue(list(self.target.parent.glob('.macseed-shell-pending-*')))
        self.assertTrue(all(state == 'unverified' for state, _ in self.states()))
        for pending in self.target.parent.glob('.macseed-shell-pending-*'): shutil.rmtree(pending)
        original_rename = self.sources.rename
        def competing_writer(a, source, b, destination, flag):
            if flag == 2:
                self.target.write_text('# competing writer must survive\n')
            return original_rename(a, source, b, destination, flag)
        with patch.object(self.sources, 'rename', side_effect=competing_writer):
            with self.assertRaises(self.sources.base.PublicationUncertain):
                self.sources.publish(self.value, str(self.home))
        retained = list(self.target.parent.glob('.macseed-shell-pending-*/swap'))
        self.assertEqual(len(retained), 1)
        self.assertEqual(retained[0].read_bytes(), b'# competing writer must survive\n')
        for pending in self.target.parent.glob('.macseed-shell-pending-*'): shutil.rmtree(pending)
        profile = self.home / '.zprofile'
        profile.write_text("alias early='pwd'\n")
        self.target.write_bytes(self.raw)
        value = self.sources.capture(str(self.home))
        profile.write_text('# preserve profile\n'); self.target.write_text('# preserve aliases\n')
        original_publish = self.sources.publish_file
        def fail_second(home, path, additions, validate):
            if path == '.config/aliases': raise OSError('fixture second-file failure')
            return original_publish(home, path, additions, validate)
        with patch.object(self.sources, 'publish_file', side_effect=fail_second):
            with self.assertRaises(self.sources.base.PublicationUncertain):
                self.sources.publish(value, str(self.home))
        self.assertEqual(profile.read_bytes(), b"# preserve profile\nalias early='pwd'\n")
        self.assertEqual(self.target.read_bytes(), b'# preserve aliases\n')


class SSHMergeTests(unittest.TestCase):
    def test_host_evidence_safety_and_bounds(self):
        raw = b'# toolkit-ssh-snapshot: 1\n# status: ready\n# excluded-profiles: 0\n\n' + self.expected
        def observe():
            return host_presentation.observe(raw, str(self.home))
        self.path.write_bytes(self.expected)
        self.assertEqual(observe()['hosts'][0]['state'], 'matching')
        detail = observe()
        self.assertTrue(host_presentation.valid(detail, raw))
        for field, value in (('item_id', host_presentation.identity('foreign')), ('label', 'foreign'),
                             ('state', 'invented'), ('reason', 'target_conflict'), ('hostname', 'private.invalid')):
            malformed = copy.deepcopy(detail)
            malformed['hosts'][0][field] = value
            self.assertFalse(host_presentation.valid(malformed, raw))
        duplicate = copy.deepcopy(detail); duplicate['hosts'] *= 2
        self.assertFalse(host_presentation.valid(duplicate, raw))
        foreign = copy.deepcopy(detail); foreign['snapshot_id'] = 'b' * 64
        self.assertFalse(host_presentation.valid(foreign, raw))
        owner = dict(record_id='v:ssh', domain='ssh-configuration', item_id='config', predicate='supported_config_match')
        mismatch = dict(record_id='v:ssh', domain='ssh-configuration', item_id='config', comparison_kind='missing', support='supported')
        self.assertIsNone(host_presentation.comparison(detail, [mismatch], [owner], raw))
        for mode in (0o644, 0o400):
            self.path.chmod(mode)
            self.assertEqual(observe()['hosts'][0]['state'], 'unverified')
        self.path.chmod(0o600)
        subprocess.run(['/bin/chmod', '+a', 'everyone allow read', str(self.path)], check=True)
        self.assertEqual(observe()['hosts'][0]['state'], 'unverified')
        subprocess.run(['/bin/chmod', '-N', str(self.path)], check=True)
        saved = self.directory / 'saved'
        self.path.rename(saved)
        self.path.symlink_to(saved)
        self.assertEqual(observe()['hosts'][0]['state'], 'unverified')
        self.path.unlink(); saved.rename(self.path)
        pending = self.directory / '.macseed-ssh-pending-fixture'
        pending.mkdir()
        self.assertEqual(observe()['hosts'][0]['state'], 'unverified')
        pending.rmdir()
        with patch.object(host_presentation.merge, 'evidence', side_effect=['a' * 64, 'b' * 64]):
            self.assertIsNone(observe())
        oversized = raw.replace(b'Host added', b'Host ' + b'x' * 161)
        self.assertIsNone(host_presentation.observe(oversized, str(self.home)))
        self.assertEqual(self.path.read_bytes(), self.expected)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name).resolve() / 'home'
        self.directory = self.home / '.ssh'
        self.directory.mkdir(parents=True, mode=0o700)
        self.path = self.directory / 'config'
        self.original = b'# existing comment\r\nHost existing\r\n\tUser fixture\r\n HostName existing.invalid\r\n Port 2222\r\n# final comment'
        self.path.write_bytes(self.original); self.path.chmod(0o600)
        self.expected = b'Host added\n    HostName added.invalid\n'

    def publish(self):
        return ssh_merge.publish(self.expected, str(self.home), ssh_merge.evidence(str(self.home)))

    def test_merge_preserves_bytes_behavior_metadata_and_repeat(self):
        subprocess.run(['/usr/bin/xattr', '-w', 'com.macseed.fixture', 'preserve', str(self.path)], check=True)
        before = self.path.stat()
        native = ['/usr/bin/ssh', '-G', '-F', str(self.path), 'existing']
        options = subprocess.check_output(native, env=dict(os.environ, HOME=str(self.home)), stderr=subprocess.DEVNULL)
        self.assertEqual(ssh_merge.plan(self.expected, str(self.home)), ('merge', 1))
        self.assertEqual(list(self.directory.iterdir()), [self.path])
        self.assertTrue(self.publish())
        self.assertEqual(self.path.read_bytes(), self.original + b'\n' + self.expected)
        self.assertEqual(subprocess.check_output(native, env=dict(os.environ, HOME=str(self.home)), stderr=subprocess.DEVNULL), options)
        after = self.path.stat()
        self.assertEqual((after.st_uid, after.st_gid, after.st_mode), (before.st_uid, before.st_gid, before.st_mode))
        self.assertEqual(subprocess.check_output(['/usr/bin/xattr', '-p', 'com.macseed.fixture', str(self.path)]), b'preserve\n')
        retained = list(self.directory.glob('.macseed-ssh-predecessor-*'))
        self.assertEqual(len(retained), 1)
        self.assertEqual((retained[0] / 'swap').read_bytes(), self.original)
        self.assertEqual((retained[0] / 'swap').stat().st_ino, before.st_ino)
        self.assertEqual(ssh_merge.plan(self.expected, str(self.home)), ('noop', 0))
        self.assertFalse(self.publish())
        self.assertEqual(self.path.stat().st_ino, after.st_ino)
        self.assertEqual(list(self.directory.glob('.macseed-ssh-predecessor-*')), retained)

    def test_multiple_missing_with_existing_match_and_comments_only(self):
        selected = (b'Host existing\n    HostName existing.invalid\n    User fixture\n    Port 2222\n' +
                    self.expected + b'Host second\n    HostName second.invalid\n')
        merged, count = ssh_merge.candidate(selected, self.original)
        self.assertEqual(count, 2)
        self.assertEqual(merged, self.original + b'\n' + self.expected + b'Host second\n    HostName second.invalid\n')
        self.assertEqual(ssh_merge.candidate(self.expected, b'# comment'), (b'# comment\n' + self.expected, 1))

    def test_conflicting_ambiguous_and_unsupported_profiles_refused(self):
        for raw in (self.expected.replace(b'added.invalid', b'other.invalid'),
                    self.expected.replace(b'Host added', b'Host Added'),
                    self.expected * 2, self.expected + self.expected.replace(b'Host added', b'Host Added'),
                    b'Include other\n', b'Match all\n', b'Host *\n HostName wildcard.invalid\n',
                    b'User global\n', self.original + b'\n Compression yes\n'):
            with self.subTest(raw=raw), self.assertRaises((ValueError, OSError)):
                ssh_merge.candidate(self.expected, raw)
        with self.assertRaises(ValueError):
            ssh_merge.candidate(self.expected + b'    IdentityFile ~/.ssh/key\n', self.original)

    def test_links_permissions_ownership_acl_and_metadata_refused(self):
        self.path.chmod(0o644)
        with self.assertRaises(ValueError): self.publish()
        self.path.chmod(0o600)
        self.directory.chmod(0o755)
        with self.assertRaises(ValueError): self.publish()
        self.directory.chmod(0o700)
        other = self.home / 'other'
        os.link(self.path, other)
        with self.assertRaises(ValueError): self.publish()
        other.unlink()
        self.path.rename(other); self.path.symlink_to(other)
        with self.assertRaises((ValueError, OSError)): self.publish()
        self.path.unlink(); other.rename(self.path)
        with patch.object(ssh_merge.os, 'getuid', return_value=os.getuid() + 1), self.assertRaises(ValueError):
            self.publish()
        subprocess.run(['/bin/chmod', '+a', 'everyone allow read', str(self.path)], check=True)
        with self.assertRaises(ValueError): self.publish()
        self.assertEqual(self.path.read_bytes(), self.original)

    def test_unsafe_ancestor_and_unqualified_filesystem_refused(self):
        self.home.chmod(0o777)
        with self.assertRaises(ValueError): self.publish()
        self.home.chmod(0o700)
        alias = self.home.parent / 'alias'
        alias.symlink_to(self.home, target_is_directory=True)
        with self.assertRaises((ValueError, OSError)):
            ssh_merge.plan(self.expected, str(alias))
        with patch.object(ssh_merge, 'swap_supported', side_effect=ssh_merge.Refused('publication_unavailable')):
            with self.assertRaises(ValueError): self.publish()
        self.assertEqual(list(self.directory.iterdir()), [self.path])

    def test_stale_bytes_and_identical_inode_replacement_refused(self):
        for raw in (self.original + b'\n# edit\n', self.original):
            previous = ssh_merge.evidence(str(self.home))
            replacement = self.directory / 'editor-save'
            replacement.write_bytes(raw); replacement.chmod(0o600); replacement.replace(self.path)
            with self.assertRaises(ValueError):
                ssh_merge.publish(self.expected, str(self.home), previous)
            self.assertEqual(self.path.read_bytes(), raw)
            self.assertEqual(list(self.directory.iterdir()), [self.path])

    def test_publication_failure_retains_predecessor_and_blocks_retry(self):
        with patch.object(ssh_merge, 'rename', side_effect=OSError('fixture failure')):
            with self.assertRaises(ssh_merge.PublicationUncertain) as failure: self.publish()
        self.assertTrue(failure.exception.changed)
        pending = list(self.directory.glob('.macseed-ssh-pending-*'))
        self.assertEqual(len(pending), 1)
        self.assertEqual((pending[0] / 'observed').read_bytes(), self.original)
        self.assertEqual(self.path.read_bytes(), self.original)
        with self.assertRaises(ValueError): ssh_merge.plan(self.expected, str(self.home))
        self.assertEqual(ssh_merge.config.assess(self.expected, str(self.home))[1], 'publication_uncertain')

    def test_staging_failure_retains_pending_without_touching_config(self):
        with patch.object(ssh_merge, 'write_private', side_effect=OSError('fixture failure')):
            with self.assertRaises(ssh_merge.PublicationUncertain) as failure: self.publish()
        self.assertTrue(failure.exception.changed)
        self.assertEqual(self.path.read_bytes(), self.original)
        self.assertEqual(len(list(self.directory.glob('.macseed-ssh-pending-*'))), 1)
        with self.assertRaises(ValueError): ssh_merge.plan(self.expected, str(self.home))

    def test_last_gap_directory_replacement_preserves_both_locations(self):
        rename = ssh_merge.rename
        moved = self.home / 'moved-ssh'
        concurrent = b'Host editor\n HostName editor.invalid\n'
        def racing_rename(source_fd, source, target_fd, target, flag):
            if flag == 2:
                self.directory.rename(moved)
                self.directory.mkdir(mode=0o700)
                self.path.write_bytes(concurrent); self.path.chmod(0o600)
            return rename(source_fd, source, target_fd, target, flag)
        with patch.object(ssh_merge, 'rename', side_effect=racing_rename):
            with self.assertRaises(ssh_merge.PublicationUncertain): self.publish()
        self.assertEqual(self.path.read_bytes(), concurrent)
        self.assertEqual(list(self.directory.iterdir()), [self.path])
        pending = next(moved.glob('.macseed-ssh-pending-*'))
        self.assertEqual((pending / 'observed').read_bytes(), self.original)
        self.assertEqual((pending / 'swap').read_bytes(), self.original)
        self.assertEqual((moved / 'config').read_bytes(), self.original + b'\n' + self.expected)

    def test_last_gap_edit_is_retained_and_never_rolled_back(self):
        rename = ssh_merge.rename
        concurrent = b'# editor content\nHost editor\n HostName editor.invalid\n'
        def racing_rename(source_fd, source, target_fd, target, flag):
            if flag == 2:
                replacement = self.directory / 'editor-save'
                replacement.write_bytes(concurrent); replacement.chmod(0o600); replacement.replace(self.path)
            return rename(source_fd, source, target_fd, target, flag)
        with patch.object(ssh_merge, 'rename', side_effect=racing_rename):
            with self.assertRaises(ssh_merge.PublicationUncertain): self.publish()
        pending = next(self.directory.glob('.macseed-ssh-pending-*'))
        self.assertEqual((pending / 'observed').read_bytes(), self.original)
        self.assertEqual((pending / 'swap').read_bytes(), concurrent)
        self.assertEqual(self.path.read_bytes(), self.original + b'\n' + self.expected)
        self.assertEqual(ssh_merge.config.assess(self.expected, str(self.home))[1], 'publication_uncertain')

    def test_interruption_after_swap_retains_actual_predecessor(self):
        script = '''import os, sys
sys.path.insert(0, sys.argv[1])
import ssh_merge
rename = ssh_merge.rename
def interrupted(*args):
    rename(*args)
    os._exit(73)
ssh_merge.rename = interrupted
ssh_merge.publish(b'Host added\\n    HostName added.invalid\\n', sys.argv[2], ssh_merge.evidence(sys.argv[2]))
'''
        result = subprocess.run([sys.executable, '-B', '-c', script, str(ROOT / 'modules/ssh'), str(self.home)],
                                env=dict(os.environ, HOME=str(self.home)), capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 73, result.stderr)
        pending = next(self.directory.glob('.macseed-ssh-pending-*'))
        self.assertEqual((pending / 'swap').read_bytes(), self.original)
        self.assertEqual(self.path.read_bytes(), self.original + b'\n' + self.expected)
        with self.assertRaises(ValueError): ssh_merge.plan(self.expected, str(self.home))


class CompareTests(unittest.TestCase):
    def test_bundle_alias_absence_with_dynamic_startup(self):
        c = shell_aliases.recovery_contract()
        self.environment.pop('ZDOTDIR', None)
        self.environment['HOME'] = str(self.home.resolve())
        source = self.root / 'source'; source.mkdir(mode=0o700)
        scripts = source / 'Scripts'; scripts.mkdir(mode=0o700)
        payload = b'#!/bin/sh\necho fixture\n'
        for name in ('linked.sh', 'standalone'):
            path = scripts / name; path.write_bytes(payload); path.chmod(0o700)
        dynamic = b'eval "$(touch "$HOME/startup-must-not-run")"\nhelper() { :; }\n'
        declarations = b"alias first='echo fixture'\nalias second='$HOME/Scripts/linked.sh'\n"
        (source / '.zshrc').write_bytes(dynamic + declarations)
        paths = ['Scripts/linked.sh', 'Scripts/standalone']
        with patch.dict(os.environ, HOME=str(source.resolve())):
            os.environ.pop('ZDOTDIR', None)
            value = c.authorize_capture(c.capture(str(source.resolve())), str(source.resolve()),
                [c.script_id(path) for path in paths], policy=c.FILE_POLICY, script_paths=paths)
        snapshot = self.generated / 'shell/zshrc.snapshot'; c.save(snapshot, value)
        self.write_blueprint(categories=('shell-zsh',), packages='')
        archive = self.make_bundle()
        target = self.home / '.zshrc'; target.write_bytes(dynamic)
        before = (target.read_bytes(), c.base.stamp(target.stat()), archive.read_bytes())
        data = self.comparison(bundle_path=str(archive))
        expected = {shell_aliases.identity('first'), shell_aliases.identity('second'), *(c.file_identity(path) for path in paths)}
        self.assertEqual({row['item_id']: row['comparison_kind'] for row in data['comparison_records']}, dict.fromkeys(expected, 'missing'))
        self.assertEqual(data['comparison']['counts']['missing'], 4)
        self.assertEqual(data['comparison']['counts']['unverified'], 0)
        self.assertEqual(data['comparison']['counts']['unresolved'], 1)
        self.assertTrue(any(row['code'] == 'partial_source_coverage' for row in data['records']['diagnostics']))
        self.assertEqual(sum(row['predicate'] == 'script_file' for row in data['records']['verification_records']), 2)
        self.assertEqual(sum(row['predicate'] == 'alias_recovery' for row in data['records']['verification_records']), 2)
        self.assertEqual((target.read_bytes(), c.base.stamp(target.stat()), archive.read_bytes()), before)
        self.assertFalse((self.home / 'startup-must-not-run').exists())
        self.assertFalse((self.home / 'Scripts').exists())
        # V5 now qualifies bounded append to this known dynamic source. Check
        # and planning still neither execute startup code nor publish any file.
        planned = c.plan(value, str(self.home))
        self.assertIsNone(planned['reason'])
        self.assertEqual(set(planned['writes']), {'.zshrc', *paths})
        self.assertEqual(planned['writes']['.zshrc'][0], dynamic + declarations)
        self.assertEqual({path: planned['writes'][path] for path in paths},
                         dict.fromkeys(paths, (payload, 0o700)))
        self.assertEqual((target.read_bytes(), c.base.stamp(target.stat()), archive.read_bytes()), before)
        self.assertFalse((self.home / 'Scripts').exists())
        self.assertFalse((self.home / 'startup-must-not-run').exists())

    def test_bundle_mixed_script_comparison_status_and_counts(self):
        contract = shell_aliases.recovery_contract()
        self.environment.pop('ZDOTDIR', None)
        self.environment['HOME'] = str(self.home.resolve())
        source = self.root / 'source'
        source.mkdir(mode=0o700)
        script = source / '.local/bin/fixture'
        script.parent.mkdir(parents=True)
        raw = b'#!/bin/sh\ntouch "$HOME/script-must-not-run"\n'
        script.write_bytes(raw); script.chmod(0o700)
        startup = "alias first='$HOME/.local/bin/fixture'\nalias second='$HOME/.local/bin/fixture'\n"
        (source / '.zshrc').write_text(startup)
        with patch.dict(os.environ, HOME=str(source.resolve())):
            os.environ.pop('ZDOTDIR', None)
            observed = contract.capture(str(source.resolve()))
            value = contract.authorize_capture(observed, str(source.resolve()), [contract.script_id('.local/bin/fixture')], policy=contract.OPAQUE_POLICY)
        directory = self.generated / 'shell'; directory.mkdir()
        snapshot = directory / 'zshrc.snapshot'
        self.write_blueprint(categories=('shell-zsh',), packages='')
        (self.home / '.zshrc').write_text(startup)
        target = self.home / '.local/bin/fixture'; target.parent.mkdir(parents=True)
        identity = contract.file_identity('.local/bin/fixture')
        for aliases in ([], ['first'], ['first', 'second']):
            selected = contract.select(value, {*aliases, identity})
            snapshot.write_bytes(contract.encode(selected)); snapshot.chmod(0o600)
            archive = self.make_bundle()
            for condition, expected in [('match', 'matching'), ('missing', 'missing'), ('bytes', 'differing'),
                                        ('mode', 'differing'), ('unsafe', 'unverified'), ('link', 'unverified')]:
                with self.subTest(aliases=aliases, condition=condition):
                    target.unlink(missing_ok=True)
                    if condition == 'link': target.symlink_to(script)
                    elif condition != 'missing':
                        target.write_bytes(raw + (b'# modified\n' if condition == 'bytes' else b''))
                        target.chmod(0o777 if condition == 'unsafe' else 0o755 if condition == 'mode' else 0o700)
                    data = self.comparison(bundle_path=str(archive))
                    rows = data['comparison_records']
                    files = [row for row in rows if row['item_id'] == identity]
                    self.assertEqual(len(files), 1)
                    self.assertEqual(files[0]['comparison_kind'], expected)
                    self.assertEqual(len(rows), len(aliases) + 1)
                    self.assertEqual(sum(data['comparison']['counts'][key] for key in ('matching','missing','differing','unverified')), len(rows))
                    self.assertEqual(data['reference_presentation']['shell_script_labels'], {identity: '.local/bin/fixture'})
                    self.assertEqual(sum(row['predicate'] == 'script_file' for row in data['records']['verification_records']), 1)
                    if expected != 'matching':
                        self.assertFalse(any(row['comparison_kind'] == 'matching' for row in rows), 'Alias cannot conceal its selected file dependency')
                    self.assertNotIn('touch', json.dumps(data))
                    self.assertFalse((self.home / 'script-must-not-run').exists())
        # An unselected dependency has no payload, file requirement or file label.
        target.unlink(); target.write_bytes(raw); target.chmod(0o700)
        snapshot.write_bytes(contract.encode(observed))
        data = self.comparison(bundle_path=str(self.make_bundle()))
        self.assertEqual(len(data['comparison_records']), 2)
        self.assertFalse(any(row['predicate'] == 'script_file' for row in data['records']['verification_records']))
        self.assertFalse(data['reference_presentation'].get('shell_script_labels'))

    def test_bundle_host_detail_scope_counts_and_privacy(self):
        self.environment['HOME'] = str(self.home.resolve())
        payload = b'Host zebra\n    HostName secret-address.invalid\n    User privateuser\nHost alpha\n    HostName other.invalid\n'
        target = self.ssh_reference(payload)
        cases = [
            (payload, ['matching', 'matching'], 'matching'),
            (payload.split(b'Host alpha')[0], ['matching', 'missing'], 'missing'),
            (payload.replace(b'other.invalid', b'conflict.invalid'), ['matching', 'differing'], 'differing'),
            (b'Host zebra\n HostName conflicting.invalid\n', ['differing', 'missing'], 'differing'),
            (b'Include other\n' + payload, ['unsupported', 'unsupported'], 'unverified'),
        ]
        for actual, states, aggregate in cases:
            with self.subTest(states=states):
                target.write_bytes(actual); target.chmod(0o600)
                data = self.comparison(bundle_path=str(self.make_bundle()))
                detail = data['reference_presentation']['ssh_hosts']
                self.assertEqual([row['label'] for row in detail['hosts']], ['zebra', 'alpha'])
                self.assertEqual([row['state'] for row in detail['hosts']], states)
                self.assertEqual(data['comparison']['counts'][aggregate], 1)
                self.assertEqual(len(data['comparison_records']), 1)
                self.assertEqual(detail['comparison_record_id'], data['comparison_records'][0]['record_id'])
                wire = json.dumps(data)
                for private in ('secret-address.invalid', 'privateuser', 'HostName', 'IdentityFile'):
                    self.assertNotIn(private, wire)
                public = dict(data); public.pop('reference_presentation')
                self.assertNotIn('zebra', json.dumps(public))
        # Selected snapshot order/scope, never all Hosts in the original target.
        self.ssh_reference(payload.split(b'Host alpha')[0], partial=True)
        target.write_bytes(payload); target.chmod(0o600)
        data = self.comparison(bundle_path=str(self.make_bundle()))
        self.assertEqual([h['label'] for h in data['reference_presentation']['ssh_hosts']['hosts']], ['zebra'])
        self.assertEqual(data['comparison']['counts']['matching'], 1)
        self.assertEqual(data['comparison']['counts']['unresolved'], 1)
        self.assertNotIn('ssh_hosts', self.comparison()['reference_presentation'])  # Legacy/local reference fallback.

    def test_bundle_host_detail_preserves_identity_and_unsafe_diagnostics(self):
        self.environment['HOME'] = str(self.home.resolve())
        payload = b'Host example\n    HostName hidden.invalid\n    IdentityFile ~/.ssh/private_key\n'
        target = self.ssh_reference(payload, version=2)
        target.write_bytes(payload); target.chmod(0o600)
        archive = self.make_bundle()
        data = self.comparison(bundle_path=str(archive))
        self.assertEqual(data['reference_presentation']['ssh_hosts']['hosts'][0]['state'], 'matching')
        self.assertEqual(data['comparison']['counts']['unresolved'], 1)
        self.assertTrue(any(row['item_id'] == 'identity-references' for row in data['records']['coverage_records']))
        self.assertNotIn('private_key', json.dumps(data))
        target.chmod(0o644)
        data = self.comparison(bundle_path=str(archive))
        self.assertEqual(data['reference_presentation']['ssh_hosts']['hosts'][0]['state'], 'unverified')
        self.assertEqual(data['comparison']['counts']['matching'], 0)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.project = self.root / 'project'
        self.project.mkdir()
        shutil.copytree(ROOT / 'modules', self.project / 'modules')
        shutil.copy2(ROOT / 'bootstrap.sh', self.project / 'bootstrap.sh')
        (self.project / 'config').mkdir()
        shutil.copy2(ROOT / 'config/toolkit.conf', self.project / 'config/toolkit.conf')
        self.generated = self.root / 'generated'
        self.generated.mkdir()
        self.home = self.root / 'home'
        self.home.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.mutations = self.root / 'mutations'
        self.mutations.write_text('')
        self.mock('brew', '''case "$*" in
'list --formula --full-name')
 case "$TEST_MODE" in missing) exit 0;; error) exit 2;; slow) echo $$ > "$TEST_PID"; exec sleep 30;; esac
 echo git;;
'list --cask') echo extra-app;;
'info --json=v2 --cask reference-app') echo '{"casks":[]}' ;;
*) echo "brew $*" >> "$TEST_MUTATIONS"; exit 99;; esac''')
        for name in ('sudo', 'defaults', 'killall', 'mas', 'code', 'curl', 'xcode-select'):
            self.mock(name, 'echo "$0 $*" >> "$TEST_MUTATIONS"; exit 99')
        self.temporary = self.root / 'temporary'
        self.temporary.mkdir()
        self.environment = dict(os.environ, TMPDIR=str(self.temporary), HOME=str(self.home), PATH=str(self.bin) + ':' + os.environ['PATH'],
                                TEST_MUTATIONS=str(self.mutations), TEST_MODE='matching', TEST_PID=str(self.root / 'pid'),
                                GIT_CONFIG_NOSYSTEM='1', XDG_CONFIG_HOME=str(self.home / '.config'))
        self.blueprint = self.root / 'blueprint.conf'
        self.write_blueprint()
        (self.generated / 'brew-packages.conf').write_text('git\n')

    def mock(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\n' + body + '\n')
        path.chmod(0o700)

    def write_blueprint(self, categories=(), packages='git', casks=''):
        names = ('git-configuration', 'ssh-configuration', 'vscode-settings', 'shell-zsh',
                 'macos-finder', 'macos-dock', 'macos-windows', 'macos-keyboard', 'macos-trackpad', 'macos-screenshots')
        self.blueprint.write_text('[categories]\n' + ''.join(f'{name}="{str(name in categories).lower()}"\n' for name in names) +
                                  f'[homebrew-packages]\n{packages}\n[homebrew-casks]\n{casks}\n[app-store]\n[vscode-extensions]\n[workspace-folders]\n[git-repositories]\n')

    def payload(self, **overrides):
        parameters = {} if "bundle_path" in overrides else dict(generated_dir=str(self.generated), blueprint_path=str(self.blueprint))
        parameters.update(overrides)
        return json.dumps(dict(protocol_version=1, operation_id='compare-test', operation='environment_compare', parameters=parameters)).encode()

    def invoke(self, **overrides):
        before = self.snapshot()
        result = subprocess.run(['bash', str(self.project / 'modules/core/application-interface/core.sh')],
                                input=self.payload(**overrides), env=self.environment, cwd=self.project,
                                capture_output=True, timeout=getattr(self, 'comparison_timeout', 20))
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(sum(e['type'] in ('completed', 'failed', 'cancelled') for e in events), 1)
        self.assertEqual([e['sequence'] for e in events], list(range(1, len(events) + 1)))
        self.assertEqual(self.mutations.read_text(), '')
        self.assertEqual(before, self.snapshot())
        self.assertFalse((self.project / 'logs').exists())
        self.assertFalse(list(self.project.rglob('__pycache__')))
        self.assertEqual(list(self.temporary.glob("macseed-compare-*")), [])
        return result, events

    def snapshot(self):
        return {str(p.relative_to(self.root)): p.read_bytes() for base in (self.generated, self.home, self.project / 'config') for p in base.rglob('*') if p.is_file()}

    def comparison(self, **overrides):
        result, events = self.invoke(**overrides)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(events[-1]['type'], 'completed')
        self.assertTrue(any(e['type'] == 'execution_event' and e['data']['read_only'] for e in events))
        return next(e['data'] for e in events if e['type'] == 'result')

    def make_bundle(self, secure=False):
        stage = self.root / 'bundle-stage'
        if stage.exists(): shutil.rmtree(stage)
        stage.mkdir()
        shutil.copytree(self.generated, stage / 'generated')
        (stage / 'blueprint.conf').write_text(self.blueprint.read_text() + '[git-configuration]\n')
        if secure:
            (stage / 'secure.age').write_bytes(b'age-encryption.org/v1\nopaque encrypted fixture')
        output = self.root / 'saved.mbt'
        output.unlink(missing_ok=True)
        packed = subprocess.run([sys.executable, str(self.project / 'modules/bundle/bundle.py'), 'pack',
                                str(stage), str(output), str(self.home)], capture_output=True)
        self.assertEqual(packed.returncode, 0, packed.stderr.decode())
        return output

    def ssh_reference(self, payload, *, version=1, partial=False):
        self.write_blueprint(categories=('ssh-configuration',), packages='')
        directory = self.generated / 'ssh'
        directory.mkdir(exist_ok=True, mode=0o700)
        source = directory / 'config.snapshot'
        source.write_bytes((f'# toolkit-ssh-snapshot: {version}\n# status: {"partial" if partial else "ready"}\n'
                            f'# excluded-profiles: {1 if partial else 0}\n\n').encode() + payload)
        source.chmod(0o600)
        (self.home / '.ssh').mkdir(exist_ok=True, mode=0o700)
        for name in ('ssh', 'ssh-add', 'security', 'age'):
            self.mock(name, 'echo "unexpected secure tool" >> "$TEST_MUTATIONS"; exit 99')
        return self.home / '.ssh/config'

    def test_ssh_supported_profile_conformity(self):
        payload = b'Host example\n    HostName example.invalid\n    User git\n'
        target = self.ssh_reference(payload)
        cases = (
            (payload, 'matching'),
            (b'# user comment\nHost example\n User git\n HostName example.invalid\n', 'matching'),
            (payload + b'Host unrelated\n HostName unrelated.invalid\n', 'matching'),
            (b'Host unrelated\n HostName unrelated.invalid\n', 'missing'),
            (payload.replace(b'User git', b'User other'), 'differing'),
            (payload + b' Include other\n', 'unverified'),
            (payload + b' Compression yes\n', 'unverified'),
            (payload + b'Host example\n HostName another.invalid\n', 'unverified'),
        )
        for raw, kind in cases:
            with self.subTest(kind=kind, raw=raw):
                target.write_bytes(raw)
                target.chmod(0o600)
                data = self.comparison()
                self.assertEqual(len(data['comparison_records']), 1)
                self.assertEqual(data['comparison_records'][0]['comparison_kind'], kind)
                self.assertEqual(data['comparison']['counts'][kind], 1)
        target.chmod(0o644)
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['unverified'], 1)
        self.assertEqual(data['comparison_records'][0]['reason'], 'external_management')

    def test_ssh_case_variant_aliases_remain_unverified(self):
        for source_alias, target_alias in ((b'example', b'Example'), (b'Example', b'example')):
            payload = b'Host ' + source_alias + b'\n    HostName example.invalid\n'
            target = self.ssh_reference(payload)
            variant = payload.replace(b'Host ' + source_alias, b'Host ' + target_alias)
            for raw, kind in ((payload, 'matching'), (variant, 'unverified'),
                              (variant.replace(b'example.invalid', b'other.invalid'), 'unverified'),
                              (variant + b'    Compression yes\n', 'unverified'),
                              (payload + variant, 'unverified')):
                with self.subTest(source_alias=source_alias, raw=raw):
                    target.write_bytes(raw)
                    target.chmod(0o600)
                    data = self.comparison()
                    self.assertEqual(len(data['comparison_records']), 1)
                    self.assertEqual(data['comparison']['counts'][kind], 1)
                    self.assertEqual(data['comparison']['counts']['missing'], 0)
                    if kind == 'unverified':
                        self.assertEqual(data['comparison_records'][0]['reason'], 'unsupported_predicate')
                        self.assertEqual(data['comparison']['verdict'], 'incomplete')

    def test_ssh_partial_coverage_remains_incomplete(self):
        payload = b'Host example\n    HostName example.invalid\n'
        target = self.ssh_reference(payload, partial=True)
        target.write_bytes(payload)
        target.chmod(0o600)
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['matching'], 1)
        self.assertEqual(data['comparison']['counts']['unresolved'], 1)
        self.assertEqual(data['comparison']['verdict'], 'incomplete')
        self.assertEqual([r['code'] for r in data['records']['diagnostics']], ['partial_source_coverage'])
        self.assertEqual([r['conformity'] for r in data['records']['verification_records']], ['verified'])
        coverage = [r for r in data['records']['coverage_records'] if r['domain'] == 'ssh-configuration']
        self.assertEqual(sorted(r['disposition'] for r in coverage), ['resolved', 'unresolved'])
        unresolved = next(r for r in coverage if r['disposition'] == 'unresolved')
        self.assertEqual(data['records']['diagnostics'][0]['record_id'], unresolved['record_id'])
        target.write_bytes(payload.replace(b'example.invalid', b'different.invalid'))
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['differing'], 1)
        self.assertEqual(data['comparison']['counts']['unresolved'], 1)
        self.assertEqual([r['code'] for r in data['records']['diagnostics']].count('partial_source_coverage'), 1)
        self.assertEqual([r['conformity'] for r in data['records']['verification_records']], ['mismatch'])
        self.assertTrue(data['comparison']['also_incomplete'])

    def test_ssh_v2_references_are_not_identity_evidence(self):
        payload = (b'Host example\n    HostName example.invalid\n    IdentityFile ~/.ssh/key\n'
                   b'    IdentityFile /external/other\n    IdentitiesOnly yes\n'
                   b'    AddKeysToAgent no\n    UseKeychain yes\n')
        target = self.ssh_reference(payload, version=2)
        target.write_bytes(payload)
        target.chmod(0o600)
        # Opening the reference would hang/fail: configuration observation must
        # never inspect key material, including public/private pairing.
        os.mkfifo(self.home / '.ssh/key')
        saved = self.make_bundle()
        data = self.comparison(bundle_path=str(saved))
        self.assertEqual(data['comparison']['counts']['matching'], 1)
        self.assertEqual(data['comparison']['counts']['unresolved'], 1)
        self.assertEqual(data['comparison']['verdict'], 'incomplete')
        self.assertIn('prerequisite_unmet', [r['code'] for r in data['records']['diagnostics']])
        self.assertEqual([r['item_id'] for r in data['records']['coverage_records'] if r['disposition'] == 'unresolved'], ['identity-references'])
        self.assertEqual(data['secure_check']['status'], 'absent')
        self.assertNotIn('/external', json.dumps(data))
        target.write_bytes(payload.replace(b'~/.ssh/key', b'~/.ssh/renamed'))
        data = self.comparison(bundle_path=str(saved))
        self.assertEqual(data['comparison']['counts']['differing'], 1)
        self.assertTrue(data['comparison']['also_incomplete'])

    def test_ssh_none_and_unsupported_target_coverage(self):
        payload = b'Host example\n    HostName example.invalid\n    IdentityFile none\n'
        target = self.ssh_reference(payload, version=2)
        target.write_bytes(payload)
        target.chmod(0o600)
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['matching'], 1)
        self.assertEqual(data['comparison']['counts']['unresolved'], 0)
        target.write_bytes(payload + b'Host unrelated\n HostName unrelated.invalid\n ProxyJump jump\n')
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['matching'], 1)
        self.assertEqual(data['comparison']['counts']['unresolved'], 1)
        self.assertIn('unsupported_predicate', [r['code'] for r in data['records']['diagnostics']])

    def test_ssh_merge_and_uncertain_publication_check(self):
        payload = b'Host added\n    HostName added.invalid\n'
        target = self.ssh_reference(payload)
        original = b'# preserved\nHost existing\n  HostName existing.invalid\n'
        target.write_bytes(original); target.chmod(0o600)
        home = str(self.home.resolve())
        ssh_merge.publish(payload, home, ssh_merge.evidence(home))
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['matching'], 1)
        self.assertEqual(data['comparison']['counts']['unresolved'], 0)
        self.assertTrue(target.read_bytes().startswith(original))
        pending = target.parent / '.macseed-ssh-pending-fixture'
        pending.mkdir(mode=0o700)
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['unverified'], 1)
        self.assertEqual(data['comparison']['counts']['unresolved'], 1)
        self.assertEqual(data['comparison']['verdict'], 'incomplete')
        self.assertEqual(data['comparison_records'][0]['reason'], 'operation_failed')

    def test_bundle_reference_selection_and_read_only(self):
        path = self.make_bundle(secure=True)
        data = self.comparison(bundle_path=str(path))
        self.assertEqual(data['secure_check'], dict(version=1, bundle_id=hashlib.sha256(path.read_bytes()).hexdigest(), status='available'))
        self.assertFalse(any(r['domain'] == 'secure-ssh-identities' for r in data['comparison_records']))
        self.assertEqual(data['comparison']['counts']['matching'], 1)
        self.assertFalse(data['publication_occurred'])
        self.environment['TEST_MODE'] = 'missing'
        self.assertEqual(self.comparison(bundle_path=str(path))['comparison']['counts']['missing'], 1)
        self.environment['TEST_MODE'] = 'error'
        self.assertEqual(self.comparison(bundle_path=str(path))['comparison']['verdict'], 'incomplete')
        self.environment['TEST_MODE'] = 'matching'
        # Full inventory is not selected scope; retain completeness for extras.
        self.write_blueprint(packages='', casks='')
        inventory = self.generated / 'brew-casks.conf'
        inventory.write_text('reference-app\n')
        marker = self.generated / 'provenance/homebrew-casks.sha256'
        marker.parent.mkdir()
        marker.write_text('complete ' + hashlib.sha256(inventory.read_bytes()).hexdigest() + '\n')
        data = self.comparison(bundle_path=str(self.make_bundle()))
        self.assertFalse(data['comparison_records'])
        self.assertFalse(any(r['domain'] == 'homebrew-casks' and r['disposition'] == 'resolved'
                             for r in data['records']['coverage_records']))
        self.assertEqual(data['extra']['items'], [])
        self.assertEqual(data['extra']['domains'][0]['reason'], 'category_excluded')
        self.write_blueprint(packages='', casks='reference-app')
        data = self.comparison(bundle_path=str(self.make_bundle()))
        self.assertEqual(data['extra']['items'], [{'domain': 'homebrew-casks', 'item_id': 'extra-app'}])
        # Selected subset remains narrowed even with full source inventory.
        self.write_blueprint(packages='git')
        (self.generated / 'brew-packages.conf').write_text('git\nwget\n')
        data = self.comparison(bundle_path=str(self.make_bundle()))
        self.assertEqual([r['item_id'] for r in data['comparison_records']], ['git'])
        self.write_blueprint(categories=('vscode-settings',), packages='')
        (self.generated / 'vscode').mkdir()
        (self.generated / 'vscode/settings.json').write_text('{"secret":"reference-token"}')
        target = self.home / 'Library/Application Support/Code/User'
        target.mkdir(parents=True)
        (target / 'settings.json').write_text('{"secret":"current-token"}')
        data = self.comparison(bundle_path=str(self.make_bundle()))
        self.assertEqual(data['comparison']['counts']['differing'], 1)
        self.assertNotIn('reference-token', json.dumps(data))

    def test_bundle_app_store_presentation_names(self):
        self.write_blueprint(packages='')
        self.blueprint.write_text(self.blueprint.read_text().replace('[app-store]\n', '[app-store]\n1136220934\n'))
        (self.generated / 'appstore.conf').write_text('1136220934|Infuse\n')
        self.mock('mas', '[[ "$*" == list ]] || exit 99; echo "1136220934 Infuse (8.0)"')
        data = self.comparison(bundle_path=str(self.make_bundle()))
        self.assertEqual(data['reference_presentation']['app_store_names'], {'1136220934': 'Infuse'})
        self.assertEqual(data['comparison_records'][0]['item_id'], '1136220934')
        self.assertTrue(any(g['id'] == 'Applications' and 'app-store' in g['domains']
                            for g in data['reference_presentation']['groups']))

    def test_telegram_cask_does_not_satisfy_selected_app_store_requirement(self):
        self.write_blueprint(packages='', casks='telegram')
        self.blueprint.write_text(self.blueprint.read_text().replace('[app-store]\n', '[app-store]\n747648890\n'))
        (self.generated / 'brew-casks.conf').write_text('telegram\n')
        (self.generated / 'appstore.conf').write_text('747648890|Telegram\n')
        app = self.home / 'Applications/Telegram.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'ru.keepcoder.Telegram', 'CFBundleExecutable': 'Telegram'}))
        executable = app / 'Contents/MacOS/Telegram'
        executable.write_text('#!/bin/sh\n')
        executable.chmod(0o700)
        prefix = self.root / 'brew'
        prefix.mkdir()
        metadata = self.root / 'cask.json'
        metadata.write_text(json.dumps({'casks': [{
            'token': 'telegram', 'installed': '1.0', 'tap': 'homebrew/cask',
            'disabled': False, 'version': '1.0', 'sha256': 'a' * 64,
            'url': 'https://example.invalid/telegram.dmg',
            'artifacts': [{'app': ['Telegram.app'], 'target': str(app)}]}]}))
        self.environment.update(TEST_CASK_METADATA=str(metadata), TEST_BREW_PREFIX=str(prefix))
        self.mock('brew', '''case "$*" in
'info --json=v2 --cask telegram') cat "$TEST_CASK_METADATA";;
'--prefix') echo "$TEST_BREW_PREFIX";;
'list --cask') echo telegram;;
*) echo "brew $*" >> "$TEST_MUTATIONS"; exit 99;; esac''')
        self.mock('mas', '[[ "$*" == list ]] || exit 99; exit 0')
        for parameters in ({}, {'bundle_path': str(self.make_bundle())}):
            data = self.comparison(**parameters)
            kinds = {(r['domain'], r['item_id']): r['comparison_kind'] for r in data['comparison_records']}
            self.assertEqual(kinds, {('homebrew-casks', 'telegram'): 'matching', ('app-store', '747648890'): 'missing'})
            self.assertEqual(data['comparison']['counts']['matching'], 1)
            self.assertEqual(data['comparison']['counts']['missing'], 1)
            self.assertEqual(data['comparison']['verdict'], 'differences_detected')
            self.assertNotIn('effective_selection', data)
            self.assertNotIn('application_duplicates', data)

    def test_bundle_repository_display_labels_keep_diagnostics_private(self):
        self.write_blueprint(packages='')
        names = ['macseed', 'bootstrap-test', 'private/name']
        self.blueprint.write_text(self.blueprint.read_text().replace('[git-repositories]\n', '[git-repositories]\n' + '\n'.join(names) + '\n'))
        workspace = self.generated / 'workspace'
        workspace.mkdir()
        (workspace / 'repositories.conf').write_text(''.join(
            f'[{name}]\nNAME="{name}"\nPATH="{self.home}/Projects/{index}/same"\nREMOTE="https://example.invalid/repo.git"\nDEFAULT_BRANCH="main"\nCURRENT_BRANCH="main"\nHAS_UNCOMMITTED_CHANGES="false"\nHAS_VSCODE_FOLDER="false"\nHAS_SETTINGS="false"\nHAS_TASKS="false"\nHAS_LAUNCH="false"\nHAS_EXTENSIONS="false"\n'
            for index, name in enumerate(names)))
        data = self.comparison(bundle_path=str(self.make_bundle()))
        key = lambda name: 'opaque:' + hashlib.sha256(name.encode()).hexdigest()
        self.assertEqual(data['reference_presentation']['repository_labels'], {key(name): name for name in names[:2]})
        self.assertEqual(data['comparison']['counts']['missing'], 3)
        self.assertEqual(data['comparison']['counts']['unverified'], 6)
        self.assertEqual(data['comparison']['verdict'], 'differences_detected')
        self.assertEqual(len(data['comparison_records']), 9)
        raw = json.dumps({'records': data['records'], 'comparison_records': data['comparison_records']})
        for name in names: self.assertNotIn(name, raw)
        self.assertNotIn(str(self.home), json.dumps(data))
        self.assertTrue(all(row['item_id'].startswith('opaque:') for row in data['comparison_records']))

    def test_bundle_macos_labels_reuse_capture_definitions(self):
        self.write_blueprint(categories=('macos-dock',), packages='')
        directory = self.generated / 'macos'
        directory.mkdir()
        (directory / 'dock.conf').write_text('com.apple.dock|autohide|bool|true\ncom.apple.dock|magnification|bool|false\n')
        self.mock('defaults', '[[ "$1" == read ]] || exit 99; [[ "$3" == autohide ]] && echo 1 || echo 0')
        data = self.comparison(bundle_path=str(self.make_bundle()))
        self.assertEqual(data['reference_presentation']['setting_labels']['macos-dock'], {
            'com.apple.dock/autohide': 'Auto-hide', 'com.apple.dock/magnification': 'Magnification'})

    def test_bundle_invalid_unsafe_and_changed(self):
        path = self.make_bundle()
        for parameters in ({'bundle_path': 'relative'}, {'bundle_path': str(path), 'generated_dir': str(self.generated)}):
            result, events = self.invoke(**parameters)
            self.assertEqual(events[-1]['data']['code'], 'invalid_request')
        alias = self.root / 'alias.mbt'
        alias.symlink_to(path)
        self.assertEqual(self.invoke(bundle_path=str(alias))[1][-1]['data']['code'], 'bundle_invalid')
        self.assertEqual(self.invoke(bundle_path=str(self.root / 'absent.mbt'))[1][-1]['data']['code'], 'bundle_unavailable')
        path.write_bytes(b'corrupted archive')
        self.assertEqual(self.invoke(bundle_path=str(path))[1][-1]['data']['code'], 'bundle_invalid')
        # Mutation of the reference during observation cannot publish a clean result.
        path = self.make_bundle()
        self.environment['TEST_BUNDLE'] = str(path)
        self.mock('brew', 'echo changed >> "$TEST_BUNDLE"; echo git')
        result, events = self.invoke(bundle_path=str(path))
        self.assertEqual(events[-1]['data']['code'], 'reference_changed')
        self.assertFalse(any(e['type'] == 'result' for e in events))

    def test_bundle_cancellation_cleanup(self):
        path = self.make_bundle()
        original = self.payload
        self.payload = lambda **kwargs: original(bundle_path=str(path))
        before = path.read_bytes()
        self.test_cancellation_owned_group()
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(list(self.temporary.glob("macseed-compare-*")), [])
        self.environment['TEST_MODE'] = 'matching'
        self.comparison(bundle_path=str(path))

    def test_cancel_during_bundle_validation(self):
        path = self.make_bundle()
        before = path.read_bytes()
        adapter = self.project / 'modules/core/application-interface/core.py'
        original = adapter.read_text()
        for boundary in ('                bundle.inspect_bundle(source, os.environ["HOME"])',
                         '                bundle.unpack(source, stage, os.environ["HOME"], workspace_preview=True)'):
            self.assertIn(boundary, original)
            partial_stage = '                (stage / "partial-fixture").write_bytes(b"fixture")\n' if 'unpack' in boundary else ''
            adapter.write_text(original.replace(boundary,
                partial_stage + '                os.kill(os.getpid(), signal.SIGTERM)\n' + boundary))
            result, events = self.invoke(bundle_path=str(path))
            self.assertEqual(result.returncode, 130)
            self.assertEqual(events[-1]['type'], 'cancelled')
            self.assertEqual(path.read_bytes(), before)
        adapter.write_text(original)
        self.comparison(bundle_path=str(path))

    def inject_after_cancel(self, fault):
        # Wrap the completed operation, not a textual return branch: cancel()
        # can finish through several paths after stopping and collecting readers.
        marker = self.root / 'cancel-fault-fired'
        execution = self.project / 'modules/core/application-interface/execution.py'
        execution.write_text(execution.read_text() +
            '\n_fixture_cancel = OwnedBootstrap.cancel\n'
            'def _cancel_with_fault(self):\n'
            '    result = _fixture_cancel(self)\n'
            '    assert not Path(self.item_state.name).exists()\n'
            f'    Path({str(marker)!r}).write_text(str(result))\n' +
            ''.join('    ' + line + '\n' for line in fault.splitlines()) +
            'OwnedBootstrap.cancel = _cancel_with_fault\n')
        return marker

    def test_cancel_cleanup_error_is_not_bundle_unavailable(self):
        path = self.make_bundle()
        before = path.read_bytes()
        marker = self.inject_after_cancel(
            'raise FileNotFoundError(2, "fixture staging vanished", self.item_state.name)')
        payload = self.payload
        self.payload = lambda **kwargs: payload(bundle_path=str(path))
        try:
            self.test_cancellation_owned_group(expected_code='comparison_unavailable')
        finally:
            self.assertEqual(marker.read_text(), '130', 'Cleanup fault must execute after cancellation')
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(list(self.temporary.glob("macseed-compare-*")), [])

    def deny_compare_descendant_kill(self):
        execution = self.project / 'modules/core/application-interface/execution.py'
        marker = self.root / 'kill-denied'
        # Inject at the dependency actually used by cancel. The first stop sees
        # real PermissionErrors; finally reap our disposable readers with the
        # real implementation, while preserving the unconfirmed result.
        execution.write_text(execution.read_text() + f'''
_fixture_stop = ProcessTree.stop
def _fixture_denied_stop(self):
    original_kill = os.kill
    def denied_kill(pid, sig):
        Path({str(marker)!r}).write_text('denied')
        raise PermissionError(1, 'fixture descendant stop denied')
    try:
        os.kill = denied_kill
        stopped = _fixture_stop(self)
    finally:
        os.kill = original_kill
        if not _fixture_stop(self):
            raise RuntimeError('fixture reader cleanup failed')
    return stopped
ProcessTree.stop = _fixture_denied_stop
''')
        return marker

    def test_cancel_descendant_kill_denied(self):
        marker = self.deny_compare_descendant_kill()
        self.test_cancellation_owned_group()
        self.assertEqual(marker.read_text(), 'denied', 'Owned stop must reach kill denial')

    def test_cancel_does_not_hide_source_error(self):
        path = self.make_bundle()
        # Confirm source-error precedence even with uncertain cleanup evidence;
        # the real owned readers are already stopped before injecting this state.
        marker = self.inject_after_cancel(
            'self.unknown_consequences = True\n'
            f'source = Path({str(path)!r})\nsource.unlink()\nsource.read_bytes()')
        payload = self.payload
        self.payload = lambda **kwargs: payload(bundle_path=str(path))
        try:
            self.test_cancellation_owned_group(expected_code='bundle_unavailable')
        finally:
            self.assertEqual(marker.read_text(), '130', 'Source fault must execute after cancellation')

    def test_matching_and_projections(self):
        data = self.comparison()
        self.assertTrue(data['read_only'])
        self.assertFalse(data['target_mutation_may_have_started'])
        self.assertEqual(data['comparison']['counts']['matching'], 1)
        self.assertEqual(data['comparison']['verdict'], 'no_differences_detected')
        self.assertEqual(data['comparison_records'][0]['comparison_kind'], 'matching')
        self.assertIsNone(data['comparison_records'][0]['reason'])
        self.assertEqual(data['records']['verification_records'][0]['conformity'], 'verified')
        self.assertEqual(data['verification']['verdict'], 'selected_requirements_verified')
        self.assertEqual({r['disposition'] for r in data['records']['coverage_records']}, {'resolved', 'excluded'})
        self.assertFalse(data['records']['operation_records'])

    def test_missing(self):
        self.environment['TEST_MODE'] = 'missing'
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['missing'], 1)
        self.assertEqual(data['comparison_records'][0]['reason'], 'confirmed_mismatch')
        self.assertEqual(data['comparison']['verdict'], 'differences_detected')
        self.assertEqual(data['verification']['mismatch_count'], 1)

    def test_differing_and_sensitive_contents(self):
        self.write_blueprint(categories=('vscode-settings',))
        (self.generated / 'vscode').mkdir()
        (self.generated / 'vscode/settings.json').write_text('{"secret":"reference-token"}')
        target = self.home / 'Library/Application Support/Code/User'
        target.mkdir(parents=True)
        (target / 'settings.json').write_text('{"secret":"current-token"}')
        data = self.comparison()
        row = next(r for r in data['comparison_records'] if r['domain'] == 'vscode-settings')
        self.assertEqual(row['comparison_kind'], 'differing')
        self.assertEqual(data['comparison']['counts']['differing'], 1)
        self.assertNotIn('reference-token', json.dumps(data))
        self.assertNotIn('current-token', json.dumps(data))
        self.assertNotIn(str(self.root), json.dumps(data))

    def test_observation_failure_is_unverified(self):
        self.environment['TEST_MODE'] = 'error'
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['unverified'], 1)
        self.assertEqual(data['comparison_records'][0]['reason'], 'observation_failed')
        self.assertEqual(data['comparison']['verdict'], 'incomplete')
        self.assertEqual(data['verification']['status'], 'complete')

    def test_unresolved_selection(self):
        self.write_blueprint(packages='unknown')
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['unresolved'], 1)
        self.assertEqual(data['records']['coverage_records'][0]['disposition'], 'unresolved')
        self.assertEqual(data['records']['diagnostics'][0]['code'], 'selected_input_unresolved')

    def test_invalid_reference(self):
        self.blueprint.write_text('malformed!\n')
        result, events = self.invoke()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]['data']['code'], 'reference_invalid')
        self.assertEqual(events[-1]['data']['comparison']['status'], 'incomplete')

    def test_invalid_domain_input(self):
        (self.generated / 'brew-packages.conf').write_text('invalid value!\n')
        result, events = self.invoke()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]['data']['code'], 'reference_invalid')

    def test_unavailable_and_request_validation(self):
        for overrides, code in (({'generated_dir': str(self.root / 'absent')}, 'reference_unavailable'),
                                ({'blueprint_path': str(self.root / 'absent')}, 'reference_unavailable'),
                                ({'generated_dir': 'relative'}, 'invalid_request')):
            with self.subTest(overrides=overrides):
                result, events = self.invoke(**overrides)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(events[-1]['data']['code'], code)

    def test_extra_provenance(self):
        self.write_blueprint(packages='', casks='stale')
        inventory = self.generated / 'brew-casks.conf'
        inventory.write_text('reference-app\n')
        data = self.comparison()
        self.assertEqual(data['extra']['domains'][0]['status'], 'unavailable')
        provenance = self.generated / 'provenance'
        provenance.mkdir()
        marker = provenance / 'homebrew-casks.sha256'
        marker.write_text('complete ' + hashlib.sha256(inventory.read_bytes()).hexdigest() + '\n')
        data = self.comparison()
        self.assertEqual(data['extra']['items'], [{'domain': 'homebrew-casks', 'item_id': 'extra-app'}])
        self.assertEqual(data['comparison']['counts']['extra'], 1)
        marker.write_text('complete ' + '0' * 64 + '\n')
        self.assertEqual(self.comparison()['extra']['items'], [])
        marker.write_text('complete ' + hashlib.sha256(inventory.read_bytes()).hexdigest() + '\n')
        self.mock('brew', 'echo "invalid inventory value"')
        data = self.comparison()
        self.assertEqual(data['extra']['items'], [])
        self.assertEqual(data['extra']['domains'][0]['reason'], 'invalid_target_inventory')

    def test_determinism_and_bounds(self):
        first = self.comparison()
        second = self.comparison()
        for data in (first, second):
            for row in data['records']['verification_records']:
                row.pop('observed_at')
        self.assertEqual(first, second)
        sys.path.insert(0, str(ROOT / 'modules/core/application-interface'))
        from execution import OwnedBootstrap
        from reporting import MAX_RECORDS, item
        self.assertTrue(item('git-repositories', 'https://user:token@server/private').startswith('opaque:'))
        owned = OwnedBootstrap.__new__(OwnedBootstrap)
        owned.mode = '--application-compare'
        owned.report_count = MAX_RECORDS
        owned.details = {'status': 'partial'}
        owned.comparison_records = []
        owned._record({'kind': 'comparison', 'domain': 'homebrew-packages', 'item_id': 'git'})
        self.assertEqual(owned.details['status'], 'truncated')
        self.assertEqual(owned.comparison_records, [])

    def test_invalid_and_truncated_reporting_fails_closed(self):
        entry = self.project / 'bootstrap.sh'
        for kind in ('invalid', 'truncated'):
            entry.write_text("#!/usr/bin/env python3\n" + """
import json, os
fd = int(os.environ['MACSEED_REPORT_FD'])
def write(row):
    os.write(fd, (json.dumps(row) + '\\n').encode())
""" + ("write({'kind': 'comparison', 'unexpected': 'raw secret'})\n" if kind == 'invalid' else """
for i in range(8193):
    write({'kind': 'coverage', 'record_id': 'c:' + str(i), 'domain': 'homebrew-packages',
           'item_id': 'git', 'disposition': 'resolved', 'source_status': 'unknown'})
""") + "write({'kind': 'details_complete'})\n")
            result, events = self.invoke()
            self.assertEqual(result.returncode, 2)
            self.assertEqual(events[-1]['data']['code'], 'comparison_reporting_incomplete')
            self.assertEqual(events[-1]['data']['records']['status'], kind)
            self.assertNotIn('raw secret', result.stdout.decode())
            self.assertLessEqual(len(events[-1]['data']['records']['coverage_records']), 8192)

    def test_cancellation_owned_group(self, expected_code=None):
        self.environment['TEST_MODE'] = 'slow'
        process = subprocess.Popen(['bash', str(self.project / 'modules/core/application-interface/core.sh')],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=self.environment, cwd=self.project, start_new_session=True)
        process.stdin.write(self.payload())
        process.stdin.close()
        process.stdin = None
        pid_file = self.root / 'pid'
        deadline = time.monotonic() + 10
        while not pid_file.exists() and time.monotonic() < deadline:
            time.sleep(.05)
        self.assertTrue(pid_file.exists())
        os.killpg(process.pid, signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 2 if expected_code else 130, stderr)
        events = [json.loads(line) for line in stdout.splitlines()]
        self.assertEqual(sum(e['type'] in ('completed', 'failed', 'cancelled') for e in events), 1)
        self.assertEqual(events[-1]['type'], 'failed' if expected_code else 'cancelled')
        if expected_code:
            self.assertEqual(events[-1]['data']['code'], expected_code)
        pid = int(pid_file.read_text())
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(.05)
        else:
            self.fail('Owned reader survived cancellation')
        self.assertEqual(self.mutations.read_text(), '')

    def test_cancellation_stops_term_ignoring_grandchild(self):
        code = ("import os, signal, time; from pathlib import Path; "
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                "Path(os.environ['TEST_PID']).write_text(str(os.getpid())); time.sleep(30)")
        path = self.bin / 'brew'
        path.write_text('#!/usr/bin/env python3\nimport subprocess, sys\n' +
                        'child = subprocess.Popen([sys.executable, "-c", ' + repr(code) + '])\nchild.wait()\n')
        self.test_cancellation_owned_group()

    def test_production_operation_support_and_unknown_difference(self):
        entry = self.project / 'bootstrap.sh'
        marker = 'source modules/verification/comparison.sh\n'
        entry.write_text(entry.read_text().replace(marker, marker + """
verify_brew_packages() {
    verification_coverage homebrew-packages git resolved unknown
    verification_operation homebrew-packages git inspect success
    verification_record homebrew-packages git installed mismatch supported '2026-10-01T00:00:00Z'
    verification_diagnostic "$GV_LAST_REF" confirmed_mismatch warning observation
    verification_unsupported homebrew-packages other unsupported_fixture
    verification_coverage homebrew-packages empty no_requirement observed_absent
}
"""))
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['unknown_difference'], 1)
        self.assertEqual(data['comparison']['counts']['unsupported'], 1)
        self.assertEqual(data['comparison']['counts']['unverified'], 2)
        self.assertEqual({r['reason'] for r in data['comparison_records']}, {'unknown_difference', 'unsupported_predicate'})
        self.assertEqual(data['records']['operation_records'][0]['outcome'], 'success')
        self.assertEqual(data['verification']['verdict'], 'differences_detected')
        self.assertEqual(data['comparison']['verdict'], 'incomplete')
        self.assertIn('no_requirement', {r['disposition'] for r in data['records']['coverage_records']})

    def test_git_identity_privacy(self):
        self.write_blueprint(categories=('git-configuration',), packages='')
        (self.generated / 'git.conf').write_text('[user]\nname = Private Reference\nemail = private-reference@example.invalid\n')
        (self.home / '.gitconfig').write_text('[user]\nname = Private Target\nemail = private-target@example.invalid\n')
        data = self.comparison()
        raw = json.dumps(data)
        for forbidden in ('Private Reference', 'Private Target', 'private-reference', 'private-target', str(self.root)):
            self.assertNotIn(forbidden, raw)
        self.assertEqual(data['comparison']['counts']['differing'], 2)

    def test_empty_scope_and_explicit_no_blueprint(self):
        self.write_blueprint(packages='')
        self.assertEqual(self.comparison()['comparison']['verdict'], 'no_comparable_requirements')
        # An ambient Blueprint cannot substitute for explicit null.
        self.environment['BLUEPRINT_FILE'] = str(self.blueprint)
        (self.project / 'config/blueprint.conf').write_text('malformed ambient blueprint!')
        result, events = self.invoke(blueprint_path=None)
        self.assertFalse(any(e.get('data', {}).get('code') == 'reference_invalid' and
                             any(r['domain'] == 'blueprint' for r in e['data'].get('records', {}).get('coverage_records', [])) for e in events))
        self.assertTrue(any(r['domain'] == 'homebrew-packages' for e in events if e['type'] == 'result'
                            for r in e['data']['comparison_records']))

    def test_cli_compatibility(self):
        self.environment.update(BLUEPRINT_FILE=str(self.blueprint), BLUEPRINT_GENERATED_DIR=str(self.generated))
        result = subprocess.run(['./bootstrap.sh', '--compare'], cwd=self.project, env=self.environment, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(b'No differences detected', result.stdout)
        self.assertIn(b'Matching: 1; missing: 0; differing: 0; unverified: 0', result.stdout)
        self.assertNotIn(b'comparison_records', result.stdout)
        self.assertEqual(self.mutations.read_text(), '')


spec = importlib.util.spec_from_file_location('topology_fixture', ROOT / 'scripts/test-restore-prepare.py')
topology_fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(topology_fixture)


class TopologyCompareTests(unittest.TestCase):
    """Same native Git fixtures/inspector as Restore; only read-only Compare runs."""
    comparison_timeout = 60
    mock = CompareTests.mock
    write_blueprint = CompareTests.write_blueprint
    payload = CompareTests.payload
    invoke = CompareTests.invoke
    comparison = CompareTests.comparison
    configure = topology_fixture.TopologyPreviewTests.configure
    pack = topology_fixture.RestorePrepareTests.pack

    def setUp(self):
        CompareTests.setUp(self)
        self.home = self.home.resolve()
        self.environment['HOME'] = str(self.home)
        self.environment['GIT_CONFIG_GLOBAL'] = '/dev/null'
        sys.path.insert(0, str(ROOT / 'scripts'))
        import workspace_fixture
        self.fixture = workspace_fixture
        self.contract = topology_fixture.bundle.workspace_contract()
        self.paths = ['Projects/base', 'Projects/team/demo', 'Projects/other/demo']
        self.base, self.oid = workspace_fixture.repository(self.home)
        workspace_fixture.linked(self.base, self.home / self.paths[1], self.oid, 'feature')
        workspace_fixture.linked(self.base, self.home / self.paths[2], self.oid, '')
        self.branches, self.parents = ['main', 'feature', ''], [0, 0, 0]
        self.git = shutil.which('git')
        self.environment['TEST_REAL_GIT'] = self.git
        self.mock('git', '''for word in "$@"; do
case "$word" in clone|fetch|checkout|prune|remove|reset|clean|switch|add|update-ref)
 echo mutation >> "$TEST_MUTATIONS"; exit 99;; esac
done
exec "$TEST_REAL_GIT" "$@"''')
        for name in ('age', 'ssh', 'ssh-add'):
            self.mock(name, 'echo "$0" >> "$TEST_MUTATIONS"; exit 99')
        self.stage = self.root / 'bundle-stage'
        self.stage.mkdir()
        self.archive = self.root / 'saved.mbt'
        self.configure()
        self.generated = self.stage / 'generated'
        self.blueprint = self.stage / 'blueprint.conf'

    def snapshot(self):
        result = {}
        for base in (self.generated, self.home, self.project / 'config'):
            for path in base.rglob('*'):
                info = path.lstat()
                value = os.readlink(path) if path.is_symlink() else path.read_bytes() if path.is_file() else None
                result[(base.name, str(path.relative_to(base)))] = (info.st_mode, info.st_ino, info.st_mtime_ns, value)
        return result

    def compare(self):
        before = self.archive.read_bytes(), self.blueprint.read_bytes()
        data = self.comparison(bundle_path=str(self.archive))
        self.assertEqual(before, (self.archive.read_bytes(), self.blueprint.read_bytes()))
        self.assertEqual(data['records']['operation_records'], [])
        rows = data['comparison_records']
        owners = data['records']['verification_records']
        self.assertEqual(len(rows), len(owners))
        self.assertEqual(len({(r['domain'], r['item_id'], r['predicate']) for r in owners}), len(owners))
        for row in rows:
            self.assertTrue(any(all(owner[key] == row[key] for key in ('record_id', 'domain', 'item_id')) for owner in owners))
        for kind in ('matching', 'missing', 'differing', 'unverified'):
            self.assertEqual(data['comparison']['counts'][kind], sum(row['comparison_kind'] == kind for row in rows))
        self.assertEqual(data['comparison']['counts']['unsupported'], sum(row['support'] == 'unsupported' for row in rows))
        for private in (str(self.home), '/Users/source', 'https://example.invalid', self.oid, 'private-ciphertext'):
            self.assertNotIn(private, json.dumps(data))
        self.assertFalse(data['publication_occurred'])
        self.assertFalse(data['target_mutation_may_have_started'])
        return data

    def git_rows(self, data):
        return [row for row in data['comparison_records'] if row['domain'] == 'git-repositories']

    def git_row(self, data, index):
        identity = 'opaque:' + hashlib.sha256(self.ids[index].encode()).hexdigest()
        return next(row for row in self.git_rows(data) if row['item_id'] == identity)

    def remove_linked(self, index):
        path = self.home / self.paths[index]
        admin = Path((path / '.git').read_text().strip()[8:])
        shutil.rmtree(path)
        shutil.rmtree(admin)

    def descriptor(self, *, folder_only=False, count=1):
        if folder_only:
            self.configure(folders=['Projects/data'])
        sections, categories = topology_fixture.bundle.parse_blueprint(self.blueprint.read_bytes())
        if folder_only:
            sections['git-repositories'] = []
        self.descriptor_id = self.contract.identity('workspace', 'Projects/view.code-workspace')
        folders = ([dict(domain='workspace-folders', item_id='Projects/data', subpath='', name='Data')]
                   if folder_only else [dict(domain='git-repositories', item_id=self.ids[2], subpath='', name='Code')])
        descriptors = [dict(item_id=self.descriptor_id, path='~/Projects/view.code-workspace', folders=folders)]
        if count == 2:
            descriptors.append(dict(item_id=self.contract.identity('workspace', 'Projects/other.code-workspace'),
                                    path='~/Projects/other.code-workspace', folders=folders))
        sections['vscode-workspaces'] = [row['item_id'] for row in descriptors]
        raw = '[categories]\n' + ''.join(f'{key}="{str(value).lower()}"\n' for key, value in categories.items())
        raw += ''.join('\n[' + domain + ']\n' + ''.join(item + '\n' for item in items)
                       for domain, items in sections.items() if domain != 'categories')
        self.blueprint.write_text(raw)
        (self.stage / self.contract.VSCODE).write_text(json.dumps(dict(contract=1, items=descriptors)))
        self.archive.unlink()
        self.pack(secure=True)
        return self.home / 'Projects/view.code-workspace'

    def test_matching_privacy_stable_identities_and_counts(self):
        first = self.compare()
        self.assertEqual(first['comparison']['verdict'], 'no_differences_detected')
        self.assertEqual(first['comparison']['counts']['matching'], 5)
        self.assertEqual({row['predicate'] for row in first['records']['verification_records']}, {'topology', 'directory'})
        self.assertEqual(len(self.git_rows(first)), 3)
        self.assertEqual(first['reference_presentation']['repository_labels'][self.git_row(first, 1)['item_id']], 'demo')
        self.assertEqual(first['reference_presentation']['repository_labels'][self.git_row(first, 2)['item_id']], 'demo')
        self.assertNotEqual(self.git_row(first, 1)['item_id'], self.git_row(first, 2)['item_id'])
        second = self.compare()
        for key in ('comparison', 'comparison_records', 'reference_presentation'):
            self.assertEqual(first[key], second[key])

    def test_missing_base_does_not_match_dependents(self):
        shutil.rmtree(self.home / 'Projects')
        data = self.compare()
        self.assertEqual(self.git_row(data, 0)['comparison_kind'], 'missing')
        for index in (1, 2):
            self.assertEqual((self.git_row(data, index)['comparison_kind'], self.git_row(data, index)['reason']),
                             ('unverified', 'prerequisite_unmet'))
        self.assertEqual(data['comparison']['verdict'], 'differences_detected')
        self.assertTrue(data['comparison']['also_incomplete'])

    def test_missing_linked_and_independent_clone_relationship(self):
        self.remove_linked(1)
        self.assertEqual(self.git_row(self.compare(), 1)['comparison_kind'], 'missing')
        self.fixture.repository(self.home, self.paths[1])
        data = self.compare()
        self.assertEqual(self.git_row(data, 1)['comparison_kind'], 'differing')
        self.assertFalse(data['comparison']['also_incomplete'])

    def test_origin_and_head_differences_are_not_missing(self):
        config = self.base / '.git/config'
        original = config.read_text()
        config.write_text(original.replace('repo.git', 'different.git'))
        self.assertEqual(self.git_row(self.compare(), 0)['comparison_kind'], 'differing')
        config.write_text(original)
        (self.base / '.git/refs/heads/other').write_text(self.oid + '\n')
        (self.base / '.git/HEAD').write_text('ref: refs/heads/other\n')
        self.assertEqual(self.git_row(self.compare(), 0)['comparison_kind'], 'differing')
        (self.base / '.git/HEAD').write_text('ref: refs/heads/main\n')
        tree = self.fixture.object_file(self.base / '.git', 'tree', b'')
        other = self.fixture.object_file(self.base / '.git', 'commit',
            f'tree {tree}\nauthor A <a@b> 2 +0000\ncommitter A <a@b> 2 +0000\n\nother\n'.encode())
        # Named OID is diagnostic; detached OID is an exact requirement.
        (self.base / '.git/refs/heads/main').write_text(other + '\n')
        admin = Path((self.home / self.paths[2] / '.git').read_text().strip()[8:])
        (admin / 'HEAD').write_text(other + '\n')
        data = self.compare()
        self.assertEqual(self.git_row(data, 0)['comparison_kind'], 'matching')
        self.assertEqual(self.git_row(data, 2)['comparison_kind'], 'differing')

    def test_nested_checkout_dependency(self):
        nested = 'Projects/base/nested'
        self.fixture.repository(self.home, nested)
        self.paths.append(nested); self.branches.append('main'); self.parents.append(3)
        self.configure()
        self.assertEqual(self.git_row(self.compare(), 3)['comparison_kind'], 'matching')
        (self.base / '.git/config').write_text('[core]\nrepositoryformatversion=0\nbare=false\n')
        data = self.compare()
        self.assertEqual(self.git_row(data, 0)['comparison_kind'], 'differing')
        self.assertEqual(self.git_row(data, 3)['comparison_kind'], 'unverified')

    def test_descriptor_match_missing_difference_and_dependency(self):
        path = self.descriptor(count=2)
        def row(data):
            return next(row for row in data['comparison_records'] if row['item_id'] == self.descriptor_id)
        self.assertEqual(row(self.compare())['comparison_kind'], 'missing')
        path.write_text('{// kept\n"folders":[{"path":"other/demo","name":"Code",}],"settings":{"private":"retained"}}')
        path.with_name('other.code-workspace').write_text('{"folders":[{"path":"other/demo","name":"Different"}]}')
        data = self.compare()
        self.assertEqual(row(data)['comparison_kind'], 'matching')
        self.assertEqual(row(data)['item_id'], self.descriptor_id)
        self.assertEqual(data['reference_presentation']['workspace_labels'][self.descriptor_id], 'view.code-workspace')
        self.assertTrue(any(r['predicate'] == 'folder_relationships' for r in data['records']['verification_records']))
        self.assertEqual(next(r for r in data['comparison_records'] if r['domain'] == 'vscode-workspaces'
                              and r['item_id'] != self.descriptor_id)['comparison_kind'], 'differing')
        self.remove_linked(2)
        self.assertEqual(row(self.compare())['comparison_kind'], 'unverified')

    def test_descriptor_folder_only_and_symlink_conflict(self):
        path = self.descriptor(folder_only=True)
        (self.home / 'Projects/data').mkdir()
        self.mock('git', 'echo git >> "$TEST_MUTATIONS"; exit 99')
        path.write_text('{"folders":[{"path":"data","name":"Data"}]}')
        data = self.compare()
        self.assertEqual(data['comparison']['counts']['matching'], 2)
        path.unlink(); path.symlink_to(self.home / 'Projects/data')
        self.assertEqual(next(r for r in self.compare()['comparison_records'] if r['domain'] == 'vscode-workspaces')['comparison_kind'], 'unverified')
        path.unlink()
        path.write_text('{"folders":[{"uri":"vscode-remote://private/path"}]}')
        unsupported = next(r for r in self.compare()['comparison_records'] if r['domain'] == 'vscode-workspaces')
        self.assertEqual((unsupported['comparison_kind'], unsupported['support']), ('unverified', 'unsupported'))
        path.write_text('{broken JSON')
        unreadable = next(r for r in self.compare()['comparison_records'] if r['domain'] == 'vscode-workspaces')
        self.assertEqual((unreadable['comparison_kind'], unreadable['reason']), ('unverified', 'observation_failed'))

    def test_capability_and_observation_failures(self):
        self.mock('git', 'case " $* " in *" worktree -h "*) echo "--porcelain"; exit 129;; esac\nexec "$TEST_REAL_GIT" "$@"')
        data = self.compare()
        self.assertEqual(data['comparison']['counts']['unsupported'], 3)
        self.assertTrue(all(row['comparison_kind'] == 'unverified' for row in self.git_rows(data)))
        self.mock('git', 'case " $* " in *" status "*) exit 2;; esac\nexec "$TEST_REAL_GIT" "$@"')
        data = self.compare()
        self.assertEqual(self.git_row(data, 0)['reason'], 'observation_failed')
        self.assertEqual(data['comparison']['counts']['unsupported'], 0)

    def test_changed_evidence_never_retains_match_or_difference(self):
        sys.path.insert(0, str(ROOT / 'modules/bootstrap/workspace'))
        import topology_preview
        files = topology_fixture.bundle.validate_archive(self.archive)
        first = dict(domain='git-repositories', item_id='1', checkout_id=self.ids[0],
                     disposition='satisfied', action='none', reason=None, difference='unknown')
        second = dict(first, disposition='conflict', difference='different')
        with patch.object(topology_preview.Inspector, 'plan', side_effect=[[first], [second]]):
            rows = list(topology_preview.comparison_records(files, str(self.home), None))
        self.assertEqual(rows[0][3:], ('2', 'supported', 'observation_failed', 'unknown'))

    def test_live_changed_observation_and_locked_metadata(self):
        self.paths, self.branches, self.parents = self.paths[:1], self.branches[:1], [0]
        self.configure()
        self.environment['TEST_OBSERVATIONS'] = str(self.root / 'observation-count')
        self.mock('git', '''case " $* " in *" status "*)
count=0
[[ ! -f "$TEST_OBSERVATIONS" ]] || read -r count < "$TEST_OBSERVATIONS"
count=$((count + 1))
echo "$count" > "$TEST_OBSERVATIONS"
if [[ "$count" -eq 1 ]]; then printf ' M tracked.txt\\0'; exit 0; fi
;; esac
exec "$TEST_REAL_GIT" "$@"''')
        data = self.compare()
        self.assertEqual(data['comparison']['verdict'], 'incomplete')
        self.assertEqual(data['comparison']['counts']['unverified'], 3)
        self.assertTrue(all(row['reason'] == 'observation_failed' for row in data['comparison_records']))
        self.mock('git', 'exec "$TEST_REAL_GIT" "$@"')
        (self.base / '.git/index.lock').write_text('retained lock')
        data = self.compare()
        self.assertEqual(self.git_row(data, 0)['comparison_kind'], 'unverified')
        self.assertEqual(self.git_row(data, 0)['reason'], 'prerequisite_unmet')

    def test_non_git_destination_and_symlink_never_match(self):
        self.paths, self.branches, self.parents = self.paths[:2], self.branches[:2], [0, 0]
        self.configure()
        self.remove_linked(1)
        destination = self.home / self.paths[1]
        destination.mkdir()
        (destination / 'user-data').write_text('retained')
        self.assertEqual(self.git_row(self.compare(), 1)['comparison_kind'], 'unverified')
        shutil.rmtree(destination)
        destination.symlink_to(self.base, target_is_directory=True)
        self.assertEqual(self.git_row(self.compare(), 1)['comparison_kind'], 'unverified')

    def test_changed_bundle_and_stage_cannot_publish_results(self):
        self.paths, self.branches, self.parents = self.paths[:1], self.branches[:1], [0]
        self.configure()
        # A hostile observer changing private reference bytes is detected before
        # result publication; the fixture writes neither target nor local config.
        self.environment['TEST_REFERENCE'] = str(self.archive)
        original = self.archive.read_bytes()
        self.mock('git', 'printf changed >> "$TEST_REFERENCE"\nexec "$TEST_REAL_GIT" "$@"')
        result, events = self.invoke(bundle_path=str(self.archive))
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]['data']['code'], 'reference_changed')
        self.assertFalse(any(event['type'] == 'result' for event in events))
        self.archive.write_bytes(original)
        self.mock('git', 'printf "\\n" >> "$BLUEPRINT_GENERATED_DIR/workspace/topology.json"\nexec "$TEST_REAL_GIT" "$@"')
        result, events = self.invoke(bundle_path=str(self.archive))
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]['data']['code'], 'reference_changed')
        self.assertFalse(any(event['type'] == 'result' for event in events))
        self.assertEqual(self.archive.read_bytes(), original)

    def test_invalid_dependency_payload_rejected_before_observation(self):
        import io
        import tarfile
        self.descriptor()
        descriptors = self.stage / self.contract.VSCODE
        payload = json.loads(descriptors.read_bytes())
        payload['items'][0]['folders'] = [dict(domain='workspace-folders', item_id='Projects/base', subpath='')]
        descriptors.write_text(json.dumps(payload))
        self.archive.unlink()
        self.pack()
        expected = topology_fixture.bundle.validate_archive(self.archive)
        with tarfile.open(self.archive, 'r:') as stream:
            content = {member.name: stream.extractfile(member).read() for member in stream if member.isfile()}

        def repack():
            with tarfile.open(self.archive, 'w', format=tarfile.USTAR_FORMAT) as stream:
                for name, value in content.items():
                    info = tarfile.TarInfo(name); info.size = len(value); info.mode = 0o600
                    stream.addfile(info, io.BytesIO(value))

        # The same writer must produce an accepted control Bundle before only
        # the selected dependency and its manifest checksum/size are changed.
        repack()
        self.assertEqual(topology_fixture.bundle.validate_archive(self.archive), expected)
        manifest = json.loads(content['manifest.json'])
        self.assertEqual(content['blueprint.conf'].count(b'Projects/base\n'), 1)
        blueprint = content['blueprint.conf'].replace(b'Projects/base\n', b'')
        content['blueprint.conf'] = blueprint
        manifest['files']['blueprint.conf'] = dict(size=len(blueprint), sha256=hashlib.sha256(blueprint).hexdigest())
        content['manifest.json'] = json.dumps(manifest).encode()
        repack()
        with self.assertRaises(topology_fixture.bundle.WorkspaceSelectionInvalid) as rejected:
            topology_fixture.bundle.validate_archive(self.archive)
        self.assertEqual(rejected.exception.code, 'workspace_dependency_missing')
        # Any entry into target observation must fail this test, even if the
        # adapter were to report bundle_invalid after launching the collector.
        (self.project / 'bootstrap.sh').write_text('#!/bin/bash\necho target-observation >> "$TEST_MUTATIONS"\nexit 99\n')
        before = self.archive.read_bytes()
        result, events = self.invoke(bundle_path=str(self.archive))
        self.assertEqual(self.archive.read_bytes(), before)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]['data']['code'], 'bundle_invalid')
        self.assertEqual([event['data'] for event in events if event['type'] == 'execution_event'],
                         [dict(phase='bundle_validation', read_only=True)])
        self.assertFalse(any(event['type'] == 'result' for event in events))


if __name__ == '__main__':
    unittest.main()
