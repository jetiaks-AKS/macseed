"""Disposable inputs for the native RestoreTests --secure-restore-only path.

No workflows run here. Real Restore preparation/import/execution runs from Swift
through CoreRuntime. Secrets arrive on an anonymous pipe and never enter argv.
"""
import base64
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

sys.dont_write_bytecode = True
repository, root, age = map(Path, sys.argv[1:4])
flags = set(sys.argv[4:])
assert flags <= {"--two-identities", "--large-selection", "--capture-source", "--passphrase-source"} and len(flags) == len(sys.argv[4:])
two_identities = "--two-identities" in flags
core, home, stage, tools = [root / name for name in ('core', 'home', 'stage', 'bin')]
for directory in (core / 'config', core / 'scripts', core / 'bin', home, stage, tools):
    directory.mkdir(parents=True, mode=0o700)
for name in ('modules', 'bootstrap.sh', 'config/toolkit.conf', 'scripts/ssh-identity-migrate.sh', 'scripts/install-bs.sh', 'bin/bs'):
    source, target = repository / name, core / name
    shutil.copytree(source, target) if source.is_dir() else shutil.copy2(source, target)
for name, body in {'sudo': 'exit 0', 'curl': 'exit 0', 'xcode-select': 'exit 0', 'sw_vers': 'echo 99',
                   'brew': 'if [ "$1" = --prefix ]; then dirname "$(dirname "$0")"; else exit 99; fi',
                   'defaults': 'exit 99', 'killall': 'exit 99'}.items():
    (tools / name).write_text('#!/bin/sh\n' + body + '\n')
    (tools / name).chmod(0o700)
(tools / 'age').symlink_to(age)
(tools / 'bs').symlink_to(core / 'bin/bs')
os.environ.update(HOME=str(home), PATH=str(tools) + ':' + str(Path(sys.executable).parent) + ':/usr/bin:/bin:/usr/sbin:/sbin', PYTHONDONTWRITEBYTECODE='1')
sys.path[:0] = [str(core / 'modules/migration'), str(core / 'modules/bundle')]
from secret_input import tool, encrypt
import bundle

key_secret, bundle_secret = sys.stdin.buffer.read().split(b'\n')
key = root / 'disposable_identity'
code, _, _ = tool(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-f', str(key)], key_secret, secret_repeats=2)
assert code == 0, 'disposable key generation failed'
if '--capture-source' in flags:
    # Only prepare source inputs. Swift drives production Capture/Prepare/Execute;
    # no handcrafted manifest, tar or encrypted package participates in this test.
    ssh = home / '.ssh'
    ssh.mkdir(mode=0o700)
    for source, name, mode in [(key, 'id_disposable', 0o600), (key.with_suffix('.pub'), 'id_disposable.pub', 0o644)]:
        shutil.copy2(source, ssh / name)
        (ssh / name).chmod(mode)
    bootstrap = core / 'bootstrap.sh'
    marker = 'source modules/discovery/workspace.sh\n'
    disabled = ['discover_git', 'discover_ssh_configuration', 'discover_zsh', 'export_vscode_settings', 'discover_workspace',
                'export_finder_settings', 'export_dock_settings', 'export_windows_settings', 'export_keyboard_settings',
                'export_trackpad_settings', 'export_screenshots_settings']
    original = bootstrap.read_text()
    assert original.count(marker) == 1
    bootstrap.write_text(original.replace(marker, marker + ''.join(name + '() { return 1; }\n' for name in disabled)))
    (tools / 'brew').write_text('''#!/bin/sh
case "$*" in
  'list --formula'|'list --formula --full-name'|'list --formula --installed-on-request') echo fixture-formula;;
  --version) echo 'Homebrew 7.0.7';;
  help\\ *) echo "$2 --formula --cask --full-name --json --appdir";;
  'info --json=v2 --installed --cask') echo '{"casks":[]}';;
  'list --cask') exit 0;;
  --prefix) echo /opt/homebrew;;
  *) exit 99;;
esac
''')
    for name in ['code', 'mas', 'defaults', 'killall', 'curl', 'sudo']:
        (tools / name).write_text('#!/bin/sh\nexit 99\n')
        (tools / name).chmod(0o700)
    if '--passphrase-source' in flags:
        subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(ssh / 'id_plain')], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        status, _, _ = tool(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-f', str(root / 'disposable_second')], key_secret[::-1], secret_repeats=2)
        assert status == 0
        (tools / 'sudo').write_text('#!/bin/sh\nexit 0\n')
    sys.exit(0)
private, public = key.read_bytes(), key.with_suffix('.pub').read_bytes()
fingerprint = 'SHA256:' + base64.b64encode(hashlib.sha256(base64.b64decode(public.split()[1])).digest()).decode().rstrip('=')
identities = [('id_disposable', private, public)]
if two_identities:
    second = root / 'disposable_second'
    code, _, _ = tool(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-f', str(second)], key_secret, secret_repeats=2)
    assert code == 0, 'disposable key generation failed'
    identities.append(('id_second', second.read_bytes(), second.with_suffix('.pub').read_bytes()))
lines = ['toolkit-ssh-identities', 'version=1', 'count=' + str(len(identities))]
entries = []
for name, private, public in identities:
    fingerprint = 'SHA256:' + base64.b64encode(hashlib.sha256(base64.b64decode(public.split()[1])).digest()).decode().rstrip('=')
    lines.append('\t'.join([name, 'ssh-ed25519', fingerprint, str(len(private)), hashlib.sha256(private).hexdigest(),
                            str(len(public)), hashlib.sha256(public).hexdigest()]))
    entries += [('keys/' + name, private), ('keys/' + name + '.pub', public)]
manifest = ('\n'.join(lines) + '\n').encode()
payload = root / 'payload.tar'
with tarfile.open(payload, 'w', format=tarfile.USTAR_FORMAT) as archive:
    for name, raw in [('manifest', manifest)] + entries:
        member = tarfile.TarInfo(name); member.size = len(raw)
        archive.addfile(member, io.BytesIO(raw))
class Input:
    def ask(self, kind, attempt=1):
        assert kind == 'bundle_encrypt'
        return bundle_secret

blueprint = ('[categories]\n' + ''.join(f'{name}="false"\n' for name in bundle.CATEGORY_FLAGS)
             + ''.join('\n[' + name + ']\n' + ('Projects\n' if name == 'workspace-folders' else '') for name in bundle.ITEMS)).encode()
bundle.write_file(stage / 'blueprint.conf', blueprint)
bundle.write_file(stage / 'generated/workspace/folders.conf', b'Projects|workspace\n')
bundle.pack(stage, root / 'ordinary.mbt', '/Users/source')
with payload.open('rb') as plain, (stage / 'secure.age').open('wb') as destination:
    encrypt(plain.fileno(), destination, Input())
(stage / 'secure.age').chmod(0o600)
bundle.pack(stage, root / 'secure.mbt', '/Users/source')

if '--large-selection' in flags:
    # 95 available ordinary items; the native regression selects 60 + 30 + 3.
    stage = root / 'large-stage'
    stage.mkdir(mode=0o700)
    shutil.copy2(root / 'stage/secure.age', stage / 'secure.age')
    folders = [f'FixtureFolders/Folder{index:02}' for index in range(60)]
    repositories = [f'FixtureRepository{index:02}' for index in range(30)]
    packages = [f'fixture-package-{index}' for index in range(5)]
    selection = {'workspace-folders': folders, 'git-repositories': repositories, 'homebrew-packages': packages}
    blueprint = ('[categories]\n' + ''.join(f'{name}="false"\n' for name in bundle.CATEGORY_FLAGS)
                 + ''.join('\n[' + name + ']\n' + ''.join(value + '\n' for value in selection.get(name, [])) for name in bundle.ITEMS)).encode()
    bundle.write_file(stage / 'blueprint.conf', blueprint)
    bundle.write_file(stage / 'generated/workspace/folders.conf', ''.join(name + '|workspace\n' for name in folders).encode())
    bundle.write_file(stage / 'generated/workspace/repositories.conf', ''.join(
        f'[{name}]\nNAME="{name}"\nPATH="/Users/source/FixtureRepositories/{name}"\nREMOTE="https://example.invalid/{name}.git"\nCURRENT_BRANCH="main"\nDEFAULT_BRANCH="main"\n'
        'HAS_UNCOMMITTED_CHANGES="false"\nHAS_VSCODE_FOLDER="false"\nHAS_SETTINGS="false"\nHAS_TASKS="false"\nHAS_LAUNCH="false"\nHAS_EXTENSIONS="false"\n'
        for name in repositories).encode())
    bundle.write_file(stage / 'generated/brew-packages.conf', ('\n'.join(packages) + '\n').encode())
    # Read-only inventory answers only. Any install or other brew action fails.
    (tools / 'brew').write_text('#!/bin/sh\ncase "$*" in\n--prefix) echo /opt/homebrew;;\n"--version") echo "Homebrew 4.0.0";;\nhelp\\ *) echo "$2 --formula --cask --full-name --json --appdir";;\n"list --formula --full-name") printf "%s\\n" ' + ' '.join(packages) + ';;\n*) exit 99;;\nesac\n')
    (tools / 'brew').chmod(0o700)
    bundle.pack(stage, root / 'large.mbt', '/Users/source')
