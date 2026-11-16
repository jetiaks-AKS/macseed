#!/usr/bin/env python3
"""Focused native parser admission, isolation and qualification corpus checks."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import random
import select
import signal
import subprocess
import tarfile
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / 'scripts/fixtures/shell-parser'
spec = importlib.util.spec_from_file_location('shell_parser_build', ROOT / 'scripts/build-shell-parser.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class ShellParser(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='macseed-shell-tests-')
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.work = Path(cls.temporary.name)
        supplied = os.environ.get('MACSEED_TEST_PARSER_PACKAGE')
        cls.package = Path(supplied) if supplied else cls.work / 'package'
        if not supplied:
            builder.build(cls.package, [platform.machine()])
        cls.binary = cls.package / 'macseed-shell-parser'
        cls.sanitized = json.loads((cls.package / 'build.json').read_text())['sanitized']
        cls.manifest = json.loads((CORPUS / 'manifest.json').read_text())
        builder.extract_sources(cls.work)
        cls.faults = cls.work / 'faults'
        subprocess.run(['xcrun', 'clang', '-std=c11', '-O2', '-DTREE_SITTER_REUSE_ALLOCATOR',
                        '-I' + str(cls.work / 'runtime/lib/include'),
                        '-I' + str(cls.work / 'runtime/lib/src'),
                        str(CORPUS / 'faults.c'), str(cls.work / 'runtime/lib/src/lib.c'),
                        '-o', str(cls.faults)], check=True, capture_output=True)

    def parse(self, data, binary=None, arguments=()):
        environment = {'PATH': '/nonexistent', 'HOME': str(self.work / 'absent-home')}
        if self.sanitized:
            # Keep the no-tool-discovery test strict; ASan otherwise warns while
            # looking for atos on the deliberately empty PATH. Checks stay on.
            environment['ASAN_OPTIONS'] = 'symbolize=0'
            environment['UBSAN_OPTIONS'] = 'symbolize=0:halt_on_error=1'
        process = subprocess.run([str(binary or self.binary), *arguments], input=data,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=4,
                                 env=environment)
        self.assertEqual(process.stderr, b'')
        self.assertLess(len(process.stdout), 128 * 1024)
        value = json.loads(process.stdout)
        self.assertEqual(value['schema'], 1)
        self.assertEqual(value['profile'], 'zsh-default-1')
        if value['status'] == 'error':
            self.assertEqual(process.returncode, 2)
            self.assertEqual(value['definitions'], [])
            self.assertEqual(set(value), {'schema', 'profile', 'status', 'code', 'definitions'})
        else:
            self.assertEqual(process.returncode, 0)
            self.assertEqual(value['sha256'], hashlib.sha256(data).hexdigest())
            self.assertEqual(value['bytes'], len(data))
            self.assertLessEqual(value['allocation_peak'], 128 * 1024 * 1024)
            for i, definition in enumerate(value['definitions']):
                start, end = definition['span']
                self.assertTrue(0 <= start < end <= len(data))
                self.assertLessEqual(end - start, 65536)
                data[start:end].decode('utf-8')
                body_start, body_end = definition['body']
                self.assertTrue(start <= body_start < body_end <= end)
                for first, last in definition['names']:
                    self.assertTrue(start <= first < last <= body_start)
                parent = definition['parent']
                self.assertTrue(-1 <= parent < i)
                if parent >= 0:
                    first, last = value['definitions'][parent]['body']
                    self.assertTrue(first <= start < end <= last)
        return value

    def corpus(self, binary):
        for case in self.manifest:
            with self.subTest(case=case['name']):
                data = (CORPUS / case['file']).read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(), case['sha256'])
                result = self.parse(data, binary)
                if case['context'] == 'reject_encoding':
                    self.assertEqual(result['code'], 'invalid_encoding')
                elif not case['valid']:
                    self.assertEqual(result['code'], 'syntax_invalid')
                else:
                    self.assertEqual(result['code'], 'ok')
                    self.assertEqual([d['span'] for d in result['definitions']], case['expected'])

    def test_original_83_case_corpus_and_golden_spans(self):
        self.assertEqual(len(self.manifest), 83)
        self.corpus(self.binary)

    def test_x86_64_corpus_when_package_contains_slice(self):
        binary = self.package / 'macseed-shell-parser-x86_64'
        if not binary.exists():
            self.skipTest('x86_64 slice not in this developer package')
        # Failure to run the requested slice is a failure, never a silent skip.
        self.corpus(binary)

    def test_names_nested_anonymous_and_multiple_bindings_are_structural(self):
        data = b"function one two { inner() { :; }; }\n() { :; } arg\n"
        definitions = self.parse(data)['definitions']
        self.assertEqual([[data[a:b] for a, b in d['names']] for d in definitions],
                         [[b'one', b'two'], [b'inner'], []])
        self.assertEqual([d['parent'] for d in definitions], [-1, 0, -1])

    def test_utf8_nul_and_noncanonical_encoding_rejected(self):
        for invalid in (b'\0', b'\xff', b'\xc0\xaf', b'\xe0\x80\x80', b'\xed\xa0\x80',
                        b'\xf4\x90\x80\x80', b'\xf0\x80\x80\x80', b'\xe2\x82', b'\x80'):
            with self.subTest(encoding=invalid.hex()):
                self.assertEqual(self.parse(b'f() { print "' + invalid + b'"; }')['code'], 'invalid_encoding')

    def test_document_and_definition_byte_limits(self):
        self.assertEqual(self.parse(b'#' + b'x' * (131072 - 2) + b'\n')['code'], 'ok')
        self.assertEqual(self.parse(b' ' * 131073)['code'], 'input_limit')
        for length, expected in ((65536, 'ok'), (65537, 'definition_size_limit')):
            data = b'f() { print "' + b'x' * (length - len(b'f() { print ""; }')) + b'"; }'
            self.assertEqual(len(data), length)
            self.assertEqual(self.parse(data)['code'], expected)

    def test_definition_name_and_nesting_limits(self):
        for count, expected in ((512, 'ok'), (513, 'definition_count_limit')):
            data = b''.join(('f%d() { :; }\n' % i).encode() for i in range(count))
            result = self.parse(data)
            self.assertEqual(result['code'], expected)
            if expected == 'ok':
                self.assertEqual(len(result['definitions']), 512)
        data = b'function ' + b' '.join(('f%d' % i).encode() for i in range(17)) + b' { :; }'
        self.assertEqual(self.parse(data)['code'], 'name_count_limit')
        self.assertEqual(self.parse(b'f() { ' + b'{ ' * 40 + b':; ' + b'}; ' * 40 + b'}')['code'], 'nesting_limit')
        for nested, expected in ((30, 'ok'), (31, 'nesting_limit')):
            self.assertEqual(self.parse(b'f() { ' + b'{ ' * nested + b':; ' + b'}; ' * nested + b'}')['code'], expected)

    def test_heredoc_suffix_outside_definition_is_rejected(self):
        for data in (b'f() { :; } <<END\nhello\nEND\n',
                     b'outer() { inner() { :; } <<END\nhello\nEND\n}\n'):
            self.assertEqual(self.parse(data)['code'], 'boundary_uncertain')
        # Body heredocs remain admitted; a separate source-level heredoc is not
        # part of the definition and cannot change its exact bytes.
        data = b'f() { cat <<END\nbody\nEND\n}\ncat <<END\nother\nEND\n'
        result = self.parse(data)
        self.assertEqual(result['code'], 'ok')
        self.assertEqual(result['definitions'][0]['span'], [0, data.index(b'\ncat')])

    def test_dense_node_budget_and_hostile_input_are_bounded(self):
        self.assertEqual(self.parse(b':\n' * 12000)['code'], 'node_limit')
        for data in (b'f(){ ' * 25000, b'$(' * 50000, b';' * 131072):
            start = time.monotonic()
            result = self.parse(data)
            self.assertLess(time.monotonic() - start, 2.8)
            self.assertIn(result['code'], {'syntax_invalid', 'allocation_limit', 'timeout', 'nesting_limit', 'node_limit'})

    def test_json_output_budget_has_no_partial_definitions(self):
        unit = b'function ' + b' '.join(('n%d' % i).encode() for i in range(16)) + b' { :; }\n'
        self.assertEqual(self.parse(unit * 512)['code'], 'output_limit')

    def test_bundle_preparation_preserves_other_files_and_refuses_links(self):
        resources = (self.work / 'fixture.app/Contents/Resources').resolve()
        resources.mkdir(parents=True)
        marker = resources / 'unrelated'
        marker.write_bytes(b'preserve')
        builder.install_package(self.package, resources)
        helper = resources.parent / 'Helpers/macseed-shell-parser'
        self.assertEqual(helper.read_bytes(), self.binary.read_bytes())
        self.assertEqual(helper.stat().st_mode & 0o777, 0o755)
        self.assertEqual(self.parse(b'f() { :; }', helper)['code'], 'ok')
        builder.install_package(self.package, resources)
        self.assertEqual(marker.read_bytes(), b'preserve')
        notices = resources / 'ThirdPartyNotices'
        self.assertEqual({p.name for p in notices.iterdir()},
                         {'shell-parser-zsh-LICENSE.txt', 'shell-parser-runtime-LICENSE.txt',
                          'shell-parser-runtime-unicode-LICENSE.txt', 'shell-parser-build.json'})
        self.assertEqual({p.name for p in self.package.glob('*LICENSE')},
                         {'zsh-LICENSE', 'runtime-LICENSE', 'runtime-unicode-LICENSE'})
        pins = json.loads((builder.VENDOR / 'pins.json').read_text())
        for component, license_name, upstream_path in (
                ('zsh', 'zsh-LICENSE', 'LICENSE'),
                ('runtime', 'runtime-LICENSE', 'LICENSE'),
                ('runtime', 'runtime-unicode-LICENSE', 'lib/src/unicode/LICENSE')):
            with self.subTest(license=license_name):
                archive = builder.VENDOR / pins[component]['archive']
                self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), pins[component]['sha256'])
                with tarfile.open(archive) as stream:
                    matches = [m for m in stream.getmembers()
                               if m.isfile() and m.name.split('/', 1)[-1] == upstream_path]
                    self.assertEqual(len(matches), 1)
                    expected = stream.extractfile(matches[0]).read()
                self.assertEqual((self.package / license_name).read_bytes(), expected)
                notice = notices / ('shell-parser-' + license_name + '.txt')
                self.assertEqual(notice.read_bytes(), expected)
                self.assertFalse(notice.is_symlink())
                self.assertEqual(notice.stat().st_mode & 0o777, 0o644)
        helper.unlink()
        helper.symlink_to(marker)
        with self.assertRaisesRegex(ValueError, 'unsafe_bundle_output'):
            builder.install_package(self.package, resources)
        self.assertEqual(marker.read_bytes(), b'preserve')
        with self.assertRaisesRegex(ValueError, 'output_must_not_exist'):
            builder.build(self.package, [platform.machine()])

    def test_truncation_never_admits_a_completed_start_zero_definition(self):
        # Same five units/proper-prefix family as the research experiment.
        names = ['01_braces', '16_controls', '20_substitutions',
                 '23_heredoc_quoted', '25_heredoc_queue']
        count = 0
        for name in names:
            case = next(c for c in self.manifest if c['name'] == name)
            data = (CORPUS / case['file']).read_bytes()
            end = case['expected'][0][1]
            for stop in range(end):
                result = self.parse(data[:stop])
                self.assertFalse(any(d['span'][0] == 0 for d in result['definitions']))
                count += 1
        self.assertEqual(count, 570)

    def test_privacy_no_execution_no_path_or_source_output(self):
        tripwire = self.work / 'must-not-exist'
        data = (f'PRIVATE_FUNCTION_MARKER() {{ touch "{tripwire}"; }}\n'
                f'touch "{tripwire}"\nsource "{tripwire}"\n'
                'print "$(PRIVATE_COMMAND_MARKER)"\n').encode()
        result = self.parse(data)
        self.assertEqual(result['code'], 'ok')
        serialized = json.dumps(result)
        self.assertNotIn('PRIVATE_', serialized)
        self.assertNotIn(str(self.work), serialized)
        self.assertFalse(tripwire.exists())
        self.assertEqual(self.parse(data + b'"')['code'], 'syntax_invalid')
        self.assertEqual(self.parse(data, arguments=('--mode=extended',))['code'], 'invalid_request')

    def test_watchdog_covers_incomplete_stdin_and_cancellation(self):
        for terminate in (False, True):
            with subprocess.Popen([str(self.binary)], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
                start = time.monotonic()
                process.stdin.write(b'f() { :; }')
                process.stdin.flush()
                if terminate:
                    time.sleep(0.05)
                    process.send_signal(signal.SIGTERM)
                process.wait(timeout=3)
                self.assertLess(time.monotonic() - start, 2.8)
                response = json.loads(process.stdout.read())
                self.assertEqual(response['code'], 'cancelled' if terminate else 'timeout')
                self.assertEqual(response['definitions'], [])
                self.assertEqual(process.stderr.read(), b'')

    def test_supervisor_faults_allocation_output_rss_timeout_and_reaping(self):
        expected = {0: 'process_failed', 1: 'process_failed', 2: 'timeout', 3: 'output_limit',
                    4: 'process_failed', 5: 'allocation_limit', 6: 'allocation_limit',
                    7: 'allocation_limit', 8: 'memory_limit', 9: 'allocation_limit'}
        for scenario, code in expected.items():
            with self.subTest(scenario=scenario):
                process = subprocess.run([str(self.faults), str(scenario)], capture_output=True, timeout=3)
                self.assertEqual(process.returncode, 0)
                self.assertEqual(process.stdout, (code + '\n').encode())
                self.assertEqual(process.stderr, b'')

    def test_cancel_running_worker_and_closed_output_fail_without_leaks(self):
        with subprocess.Popen([str(self.faults), '10'], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE) as process:
            self.assertTrue(select.select([process.stdout], [], [], 2)[0])
            self.assertEqual(process.stdout.readline(), b'ready\n')
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=2)
            self.assertEqual(process.returncode, 0)  # The harness also checks waitpid/ECHILD.
            self.assertEqual(stdout, b'cancelled\n')
            self.assertEqual(stderr, b'')
        read_fd, write_fd = os.pipe()
        os.close(read_fd)
        try:
            process = subprocess.run([str(self.binary)], input=b'f() { :; }',
                                     stdout=write_fd, stderr=subprocess.PIPE, timeout=3)
            self.assertEqual(process.returncode, 2)
            self.assertEqual(process.stderr, b'')
        finally:
            os.close(write_fd)

    def test_seeded_mutations_never_crash_or_return_unbounded_output(self):
        generator = random.Random(0x5A5348)
        valid = [c for c in self.manifest if c['valid'] and c['group'] != 'policy']
        for index in range(128):
            case = generator.choice(valid)
            data = bytearray((CORPUS / case['file']).read_bytes())
            offset = generator.randrange(len(data))
            data[offset:offset + 1] = generator.choice([b'}', b'"', b'$(', b'\n', b'', b'\0', b'\xff'])
            with self.subTest(mutation=index):
                result = self.parse(bytes(data))
                self.assertIn(result['code'], {'ok', 'syntax_invalid', 'invalid_encoding', 'boundary_uncertain'})

    def test_version_is_fixed_and_requires_no_tool_discovery(self):
        process = subprocess.run([str(self.binary), '--version'], capture_output=True, check=True,
                                 env={'PATH': '/nonexistent'})
        result = json.loads(process.stdout)
        self.assertEqual(result['grammar'], '0.8.0')
        self.assertEqual(result['runtime'], '0.27.2')
        self.assertEqual(result['revision'], '17651db6e3a413b22e148c8a57726d4b392d10f7')


if __name__ == '__main__':
    unittest.main()
