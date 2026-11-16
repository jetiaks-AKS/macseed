#!/usr/bin/env python3
"""Offline, pinned native Shell helper build; no grammar generation or downloads."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import stat
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'modules/shell/parser'
VENDOR = SOURCE / 'vendor'


def extract_sources(destination):
    pins = json.loads((VENDOR / 'pins.json').read_text())
    for name, pin in pins.items():
        archive = VENDOR / pin['archive']
        if hashlib.sha256(archive.read_bytes()).hexdigest() != pin['sha256']:
            raise ValueError('source_checksum_mismatch')
        with tarfile.open(archive) as stream:
            total = 0
            for member in stream.getmembers():
                path = Path(*Path(member.name).parts[1:])
                prefixes = ('src/', 'common/') if name == 'zsh' else ('lib/',)
                if not str(path).startswith(prefixes):
                    continue
                if path.is_absolute() or '..' in path.parts or member.issym() or member.islnk():
                    raise ValueError('unsafe_source_archive')
                if not member.isfile():
                    continue
                total += member.size
                if total > 128 * 1024 * 1024:
                    raise ValueError('source_archive_limit')
                target = destination / name / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(stream.extractfile(member).read())
    return pins


def build(output, architectures, sanitize=False):
    if platform.system() != 'Darwin':
        raise ValueError('macos_build_required')
    if output.exists() or output.is_symlink():
        raise ValueError('output_must_not_exist')
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    compiler = subprocess.check_output(['xcrun', '--find', 'clang'], text=True).strip()
    # Lifecycle-owned scratch is always outside the checkout and removed on error.
    with tempfile.TemporaryDirectory(prefix='macseed-shell-build-') as temporary:
        work = Path(temporary)
        pins = extract_sources(work)
        package = work / 'package'
        package.mkdir()
        for architecture in architectures:
            flags = ['-std=c11', '-O2', '-fvisibility=hidden', '-DTREE_SITTER_REUSE_ALLOCATOR',
                     '-DTREE_SITTER_HIDE_SYMBOLS', '-isysroot', sdk,
                     '-target', architecture + '-apple-macos14.0',
                     '-I' + str(work / 'runtime/lib/include'), '-I' + str(work / 'runtime/lib/src'),
                     '-I' + str(work / 'zsh/src'), '-ffile-prefix-map=' + str(work) + '=/sources',
                     '-ffile-prefix-map=' + str(ROOT) + '=/macseed']
            if sanitize:
                flags += ['-fsanitize=address,undefined', '-fno-sanitize-recover=all', '-g']
            objects = []
            for name, source in [('runtime', work / 'runtime/lib/src/lib.c'),
                                 ('grammar', work / 'zsh/src/parser.c'),
                                 ('scanner', work / 'zsh/src/scanner.c'),
                                 ('helper', SOURCE / 'helper.c')]:
                target = work / (architecture + '-' + name + '.o')
                warnings = ['-Wall', '-Wextra', '-Werror'] if name == 'helper' else []
                subprocess.run([compiler, *flags, *warnings, '-c', str(source), '-o', str(target)], check=True)
                objects.append(str(target))
            binary = package / ('macseed-shell-parser-' + architecture)
            subprocess.run([compiler, *flags, *objects, '-Wl,-dead_strip',
                            '-o', str(binary)], check=True)
            if not sanitize:
                subprocess.run(['xcrun', 'strip', '-x', str(binary)], check=True)
            binary.chmod(0o755)
        if len(architectures) == 2:
            subprocess.run(['xcrun', 'lipo', '-create',
                            *[str(package / ('macseed-shell-parser-' + a)) for a in architectures],
                            '-output', str(package / 'macseed-shell-parser')], check=True)
        else:
            shutil.copy2(package / ('macseed-shell-parser-' + architectures[0]), package / 'macseed-shell-parser')
        for name in ('zsh-LICENSE', 'runtime-LICENSE', 'pins.json'):
            shutil.copyfile(VENDOR / name, package / name)
        shutil.copyfile(work / 'runtime/lib/src/unicode/LICENSE', package / 'runtime-unicode-LICENSE')
        metadata = dict(schema=1, minimum_macos='14.0', architectures=architectures,
                        sanitized=sanitize, sources=pins,
                        compiler=subprocess.check_output([compiler, '--version'], text=True).splitlines()[0],
                        sdk=subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip(),
                        binaries={p.name: dict(bytes=p.stat().st_size, sha256=hashlib.sha256(p.read_bytes()).hexdigest())
                                  for p in package.glob('macseed-shell-parser*')})
        (package / 'build.json').write_text(json.dumps(metadata, indent=2) + '\n')
        output.parent.mkdir(parents=True, exist_ok=True)
        # Reserve only our new destination. Never replace an existing package.
        output.mkdir()
        try:
            shutil.copytree(package, output, dirs_exist_ok=True)
        except BaseException:
            shutil.rmtree(output)
            raise
    return metadata


def install_package(package, resources):
    """Development app preparation only; the runtime does not discover helpers."""
    if (resources.name != 'Resources' or resources.parent.name != 'Contents'
            or resources.parent.parent.suffix != '.app'):
        raise ValueError('expected_app_resources')
    helpers = resources.parent / 'Helpers'
    notices = resources / 'ThirdPartyNotices'
    for directory in (resources.parent.parent, resources.parent, resources, helpers, notices):
        if not directory.is_absolute() or directory.resolve() != directory:
            raise ValueError('unsafe_build_directory')
        directory.mkdir(parents=True, exist_ok=True)
        value = directory.lstat()
        if not stat.S_ISDIR(value.st_mode) or value.st_uid != os.getuid() or value.st_mode & 0o022:
            raise ValueError('unsafe_build_directory')
    files = [(package / 'macseed-shell-parser', helpers / 'macseed-shell-parser', 0o755),
             (package / 'zsh-LICENSE', notices / 'shell-parser-zsh-LICENSE.txt', 0o644),
             (package / 'runtime-LICENSE', notices / 'shell-parser-runtime-LICENSE.txt', 0o644),
             (package / 'runtime-unicode-LICENSE', notices / 'shell-parser-runtime-unicode-LICENSE.txt', 0o644),
             (package / 'build.json', notices / 'shell-parser-build.json', 0o644)]
    for _, target, _ in files:
        if target.is_symlink() or (target.exists() and not target.is_file()):
            raise ValueError('unsafe_bundle_output')
    for source, target, mode in files:
        with tempfile.NamedTemporaryFile(dir=target.parent, prefix='.shell-parser-', delete=False) as stream:
            temporary = Path(stream.name)
            try:
                os.fchmod(stream.fileno(), mode)
                stream.write(source.read_bytes())
                stream.flush()
                os.fsync(stream.fileno())
                os.replace(temporary, target)
            finally:
                temporary.unlink(missing_ok=True)


def terminate_build(_signal, _frame):
    raise SystemExit(143)


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, terminate_build)
    parser = argparse.ArgumentParser(description=__doc__)
    destination = parser.add_mutually_exclusive_group(required=True)
    destination.add_argument('--output', type=Path)
    destination.add_argument('--resources', type=Path, help='Prepare dormant helper in a development app bundle')
    parser.add_argument('--arch', choices=('arm64', 'x86_64', 'universal'), default='universal')
    parser.add_argument('--sanitize', action='store_true', help='Developer ASan/UBSan build; not distributable')
    args = parser.parse_args()
    architectures = ['arm64', 'x86_64'] if args.arch == 'universal' else [args.arch]
    try:
        if args.resources:
            if args.sanitize:
                raise ValueError('sanitizer_not_allowed_in_app_bundle')
            with tempfile.TemporaryDirectory(prefix='macseed-shell-package-') as temporary:
                package = Path(temporary) / 'package'
                build(package, architectures)
                install_package(package, args.resources.absolute())
            print('Prepared dormant Shell parser in Contents/Helpers/macseed-shell-parser')
        else:
            print(json.dumps(build(args.output.absolute(), architectures, args.sanitize), indent=2))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(2, 'Shell parser build failed: ' + str(error) + '\n')
