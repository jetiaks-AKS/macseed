#!/usr/bin/env python3
"""Focused compatibility/provider tests; all mutations belong to disposable mocks."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'modules/apps/adapters'))
import homebrew
import homebrew_cask

spec = importlib.util.spec_from_file_location('restore_fixture', ROOT / 'scripts/test-restore-prepare.py')
fixture_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture_module)
bundle = fixture_module.bundle


class ExternalToolTests(unittest.TestCase):
    def fixture(self, repair=False):
        fixture = fixture_module.RestorePrepareTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        if repair:
            metadata, prefix, caskroot = fixture.repair_cask_fixture(cli=True)
            return fixture, metadata, prefix, caskroot
        metadata = fixture.cask_fixture(mixed=True)
        return fixture, metadata

    def classify(self, fixture, kind='cask', operation=None):
        if operation:
            command = 'source modules/apps/adapters/homebrew.sh; cask_application_readiness fixture-cask ' + operation + '; printf "%s" "$CASK_APPLICATION_CONDITION"'
        else:
            command = ('source modules/apps/adapters/homebrew.sh; homebrew_adapter_classify ' + kind +
                       ' fixture-' + ('cask' if kind == 'cask' else 'formula') +
                       ' >/dev/null; printf "%s" "$HOMEBREW_ADAPTER_RESULT"')
        environment = dict(fixture.environment, MACSEED_APPLICATION_EXECUTION='true')
        output = subprocess.run(['bash', '-c', command], cwd=fixture.project, env=environment,
                                capture_output=True, check=True).stdout.decode()
        return output if operation else json.loads(output)

    def launchctl_fixture(self):
        fixture, metadata, prefix, caskroot = self.fixture(repair=True)
        label = 'org.example.Fixture-SmartDelete'
        metadata['casks'][0]['artifacts'].append({'uninstall': [{'launchctl': label, 'quit': 'org.example.Fixture'}]})
        Path(fixture.environment['TEST_CASK_METADATA']).write_text(json.dumps(metadata))
        receipt = caskroot / '.metadata/INSTALL_RECEIPT.json'
        value = json.loads(receipt.read_text())
        value['uninstall_artifacts'] = [{k: v for k, v in a.items() if k != 'target'} for a in metadata['casks'][0]['artifacts']]
        receipt.write_text(json.dumps(value))
        marker = fixture.root / 'launch-job'
        fixture.environment['TEST_LAUNCH_JOB'] = str(marker)
        launchctl = fixture.root / 'bin/launchctl'
        launchctl.write_text('''#!/bin/bash
[[ "${TEST_LAUNCH_ERROR:-false}" != true ]] || exit 1
printf 'services = {}\\nPID Status Label\\n'
[[ ! -e "$TEST_LAUNCH_JOB" ]] || printf '%s\\n' org.example.Fixture-SmartDelete
exit 0
''')
        launchctl.chmod(0o700)
        helper = fixture.project / 'modules/apps/adapters/homebrew_cask.py'
        helper.write_text(helper.read_text().replace('/bin/launchctl', str(launchctl)))
        return fixture, metadata, receipt, marker, label

    def test_supported_capabilities_formula_and_cask_states(self):
        fixture, metadata = self.fixture()
        for kind in ('formula', 'cask'):
            value = self.classify(fixture, kind)
            self.assertEqual((value['state'], value['compatibility'], value['operation']),
                             ('installable', 'compatible', 'install'))
            self.assertEqual(value['provenance']['version'], '7.0.7')
            self.assertTrue(value['capabilities'])
        Path(fixture.environment['TEST_CASK_STATE'] + '.formula').touch()
        Path(fixture.environment['TEST_CASK_STATE']).touch()
        Path(fixture.environment['TEST_CASK_TARGET']).mkdir()
        app = Path(fixture.environment['TEST_CASK_TARGET'])
        import plistlib
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'org.example.Fixture', 'CFBundleExecutable': 'Fixture'}))
        binary = app / 'Contents/MacOS/Fixture'
        binary.write_text('#!/bin/sh\n'); binary.chmod(0o700)
        for kind in ('formula', 'cask'):
            self.assertEqual(self.classify(fixture, kind)['state'], 'satisfied')
        self.assertFalse(Path(fixture.environment['TEST_CASK_LOG']).exists())

    def test_unknown_and_malformed_metadata_fail_closed(self):
        fixture, metadata = self.fixture()
        metadata['casks'][0]['artifacts'].append({'pkg': ['unsafe.pkg']})
        path = Path(fixture.environment['TEST_CASK_METADATA'])
        path.write_text(json.dumps(metadata))
        self.assertEqual(self.classify(fixture)['compatibility'], 'item_unsupported')
        for value in ('not json', '{"casks":[]}', '{"casks":[{"token":"foreign"}]}'):
            path.write_text(value)
            observed = self.classify(fixture)
            self.assertIn(observed['state'], ('observation_error', 'incompatible'))
            self.assertFalse(Path(fixture.environment['TEST_CASK_LOG']).exists())

    def test_capability_missing_and_tool_unavailable(self):
        fixture, _ = self.fixture()
        brew = fixture.root / 'bin/brew'
        brew.write_text(brew.read_text().replace('help\\ *) echo', 'help\\ *) exit 2; echo'))
        value = self.classify(fixture)
        self.assertEqual((value['state'], value['compatibility']), ('incompatible', 'capability_unavailable'))
        with patch.object(homebrew.shutil, 'which', return_value=None):
            self.assertEqual(homebrew.probe('cask')['compatibility'], 'tool_unavailable')

    def test_failed_observation_cannot_reuse_previous_satisfied_state(self):
        fixture, _ = self.fixture()
        brew = fixture.root / 'bin/brew'
        brew.write_text(brew.read_text().replace('  "info --json=v2 --cask fixture-cask")',
            '  "info --json=v2 --cask fixture-cask") [[ "${TEST_INFO_FAIL:-false}" != true ]] || exit 2;'))
        command = ('source modules/apps/adapters/homebrew.sh; HOMEBREW_ADAPTER_STATE=satisfied; '
                   'export TEST_INFO_FAIL=true; homebrew_adapter_classify cask fixture-cask >/dev/null; '
                   'printf "%s" "$HOMEBREW_ADAPTER_RESULT"')
        output = subprocess.run(['bash', '-c', command], cwd=fixture.project,
                                env=dict(fixture.environment, MACSEED_APPLICATION_EXECUTION='true'),
                                capture_output=True, check=True)
        value = json.loads(output.stdout)
        self.assertEqual((value['state'], value['reason']), ('observation_error', 'homebrew_unavailable'))

    def test_launchctl_absent_is_repairable_job_file_error_block(self):
        fixture, metadata, receipt, marker, label = self.launchctl_fixture()
        self.assertEqual(self.classify(fixture)['state'], 'repairable')
        marker.touch()
        self.assertEqual(self.classify(fixture)['state'], 'unsupported')
        marker.unlink()
        candidates = [fixture.home / 'Library/LaunchAgents' / (label + '.plist'),
                      fixture.home / 'Library/LaunchDaemons' / (label + '.plist'),
                      fixture.project / label]
        for path in candidates:
            path.parent.mkdir(parents=True, exist_ok=True)
            for symlink in (False, True):
                if symlink: path.symlink_to('/missing/launch-agent')
                else: path.write_text('foreign cleanup target')
                self.assertIn(self.classify(fixture)['state'], ('unsupported', 'observation_error'))
                path.unlink()
        fixture.environment['TEST_LAUNCH_ERROR'] = 'true'
        value = self.classify(fixture)
        self.assertEqual((value['state'], value['reason']), ('observation_error', 'cask_launchctl_observation_failed'))
        self.assertFalse(Path(fixture.environment['TEST_CASK_LOG']).exists())

    def test_launchctl_label_grammar_and_receipt_mismatch(self):
        for value in ('org.example.*', '/Library/unsafe', '--job', 'org.example bad', 'org.example\njob', ['org.example.safe', 'bad']):
            with self.subTest(value=value), self.assertRaises(homebrew_cask.Unsafe):
                homebrew_cask.lifecycle([{'uninstall': [{'launchctl': value}]}])
        fixture, metadata, receipt, marker, label = self.launchctl_fixture()
        value = json.loads(receipt.read_text())
        value['uninstall_artifacts'][-1]['uninstall'][0]['launchctl'] = 'org.example.Other'
        receipt.write_text(json.dumps(value))
        self.assertEqual(self.classify(fixture)['state'], 'repairable')

    def test_launchctl_reobserved_after_dependencies_blocks_mutation(self):
        fixture, metadata, receipt, marker, label = self.launchctl_fixture()
        fixture.pack()
        prepared = fixture.plan_result()
        self.assertTrue(prepared['readiness']['ready'], prepared)
        executor = fixture.project / 'modules/apps/adapters/homebrew_items.py'
        # State changes after shell qualification, during dependency resolution.
        executor.write_text(executor.read_text().replace(
            '            else:\n                status, _ = self.run(command)',
            "            else:\n                Path(os.environ['TEST_LAUNCH_JOB']).touch()\n                status, _ = self.run(command)"))
        result, events = fixture.execute(prepared['prepared_plan_id'])
        self.assertEqual(result.returncode, 2, events)
        self.assertFalse(Path(fixture.environment['TEST_CASK_LOG']).exists())
        records = events[-1]['data']['verification']['details']['operation_records']
        self.assertTrue(any(row['outcome'] == 'skipped' and row['reason'] == 'cask_target_conflict' for row in records), records)
        self.assertEqual(events[-1]['data']['verification']['status'], 'complete')

    def test_bundle_provenance_optional_and_version_not_a_gate(self):
        fixture, _ = self.fixture()
        fixture.pack()
        self.assertEqual(bundle.inspect_bundle(fixture.archive, str(fixture.home))['external_tools'], {})
        fixture.archive.unlink()
        provenance = fixture.stage / 'generated/provenance/homebrew.json'
        provenance.parent.mkdir(parents=True)
        provenance.write_text(json.dumps({'homebrew': {'version': '6.0.0'}}))
        fixture.pack()
        info = bundle.inspect_bundle(fixture.archive, str(fixture.home))
        self.assertEqual(info['external_tools']['homebrew']['version'], '6.0.0')
        prepared = fixture.plan_result()
        self.assertTrue(prepared['readiness']['ready'], prepared)
        self.assertEqual(self.classify(fixture)['provenance']['version'], '7.0.7')
        brew = fixture.root / 'bin/brew'
        brew.write_text(brew.read_text().replace('Homebrew 7.0.7', 'Homebrew 99.1.0'))
        self.assertEqual(self.classify(fixture)['compatibility'], 'compatible')
        later = fixture.plan_result()
        self.assertTrue(later['readiness']['ready'])
        self.assertEqual(later['prepared_plan_id'], prepared['prepared_plan_id'])
        for invalid in ({'homebrew': {'version': 7}}, {'homebrew': {'version': '7', 'capabilities': []}}, {'unexpected': {}}):
            with self.assertRaises(bundle.Invalid):
                bundle.external_tools_provenance(invalid)


if __name__ == '__main__':
    unittest.main()
