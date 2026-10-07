"""Read-only public CLI capability/provenance probe for the Homebrew adapter.

Help is the public command surface; version is context, never an allowlist.
Installed receipts are inspected separately as inert evidence, never Ruby code.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'core'))
from external_tool import result


ENV = dict(os.environ, HOMEBREW_NO_AUTO_UPDATE='1', HOMEBREW_NO_SUDO='1',
           HOMEBREW_NO_ASK='1', HOMEBREW_NO_ENV_HINTS='1')


def read(command):
    process = subprocess.run(command, env=ENV, stdin=subprocess.DEVNULL,
                             capture_output=True, timeout=30, check=False)
    if process.returncode:
        raise OSError('public interface unavailable')
    return process.stdout.decode('utf-8').strip()


def probe(kind, operation='install'):
    if kind not in ('formula', 'cask') or operation not in ('install', 'reinstall'):
        return result('homebrew', 'incompatible', 'capability_unavailable',
                      'homebrew_capability_unavailable')
    executable = shutil.which('brew')
    if not executable:
        return result('homebrew', 'incompatible', 'tool_unavailable',
                      'homebrew_installation_requires_interaction')
    provenance = {'executable': executable}
    capabilities = []
    try:
        from homebrew_lifecycle import pending
        if pending():
            return result('homebrew', 'incompatible', 'capability_unavailable',
                          'privileged_lifecycle_unknown', operation)
        version = read(['brew', '--version']).splitlines()[0]
        if not version.startswith('Homebrew ') or len(version) > 256:
            raise ValueError('unexpected version observation')
        provenance['version'] = version.removeprefix('Homebrew ')
        prefix = read(['brew', '--prefix'])
        if prefix not in ('/opt/homebrew', '/usr/local'):
            return result('homebrew', 'incompatible', 'metadata_incompatible',
                          'homebrew_metadata_incompatible', provenance=provenance)
        provenance['prefix'] = prefix
        commands = [('list', ['--' + kind] + (['--full-name'] if kind == 'formula' else [])),
                    ('info', ['--json', '--' + kind]),
                    (operation, ['--cask', '--appdir'] if kind == 'cask' else [])]
        for command, flags in commands:
            try:
                help_text = read(['brew', 'help', command])
            except OSError:
                help_text = ''
            if command not in help_text or any(flag not in help_text for flag in flags):
                return result('homebrew', 'incompatible', 'capability_unavailable',
                              'homebrew_capability_unavailable', operation,
                              provenance, capabilities)
            capabilities.append(command + ':' + kind)
        return result('homebrew', 'satisfied', 'compatible', operation=operation,
                      provenance=provenance, capabilities=capabilities)
    except (OSError, ValueError, IndexError, subprocess.TimeoutExpired):
        return result('homebrew', 'observation_error', 'observation_failure',
                      'homebrew_unavailable', provenance=provenance,
                      capabilities=capabilities)


def main():
    if sys.argv[1:2] == ['probe']:
        value = probe(*sys.argv[2:])
    elif sys.argv[1:2] == ['result']:
        state, compatibility, reason, operation, context = sys.argv[2:]
        observed = json.loads(context)
        value = result('homebrew', state, compatibility, reason or None,
                       operation or None, observed.get('provenance'),
                       observed.get('capabilities', []))
    else:
        return 2
    print(json.dumps(value, sort_keys=True))
    return 0 if value['compatibility'] in ('compatible', 'item_unsupported') else 2


if __name__ == '__main__':
    sys.exit(main())
