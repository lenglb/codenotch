#!/usr/bin/env python3
"""Verify the shipped ZIP and start its exact binary without polling accounts."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
import uuid

HELPERS = {
    'Codenotch Codex.app': 'codex',
    'Codenotch Claude.app': 'claude',
    'Codenotch Antigravity.app': 'gemini',
}


def stop(process):
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()

archive = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='codenotch-package-') as directory:
    subprocess.run(['ditto', '-x', '-k', str(archive), directory], check=True)
    apps = list(Path(directory).glob('*.app'))
    if len(apps) != 1:
        raise SystemExit('Expected exactly one app in the archive')
    app = apps[0]
    binary = app / 'Contents/MacOS/Codenotch'
    linked = subprocess.check_output(['otool', '-L', str(binary)], text=True)
    if 'Sparkle.framework' in linked or (app / 'Contents/Frameworks/Sparkle.framework').exists():
        raise SystemExit('The fork must not link or embed Sparkle')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)

    with (app / 'Contents/Info.plist').open('rb') as info_file:
        main_bundle_id = plistlib.load(info_file).get('CFBundleIdentifier')
    helpers_directory = app / 'Contents/Helpers'
    if not helpers_directory.is_dir():
        raise SystemExit('The provider Helpers directory is missing')
    packaged_helpers = {path.name: path for path in helpers_directory.iterdir()}
    if set(packaged_helpers) != set(HELPERS):
        raise SystemExit(f'Expected exactly these provider helpers: {", ".join(HELPERS)}')
    bundle_ids = set()
    helper_binaries = []
    for name, provider_id in HELPERS.items():
        helper = packaged_helpers[name]
        with (helper / 'Contents/Info.plist').open('rb') as info_file:
            info = plistlib.load(info_file)
        if info.get('CodenotchProviderID') != provider_id:
            raise SystemExit(f'{name} has the wrong CodenotchProviderID')
        icon = helper / 'Contents/Resources/ProviderIcon.icns'
        if info.get('CFBundleIconFile') != 'ProviderIcon' or not icon.is_file():
            raise SystemExit(f'{name} is missing its offline Dock icon')
        bundle_id = info.get('CFBundleIdentifier')
        if not bundle_id or bundle_id == main_bundle_id or bundle_id in bundle_ids:
            raise SystemExit(f'{name} does not have a distinct bundle identifier')
        bundle_ids.add(bundle_id)
        helper_binary = helper / 'Contents/MacOS' / info['CFBundleExecutable']
        helper_linked = subprocess.check_output(['otool', '-L', str(helper_binary)], text=True)
        forbidden = ('Sparkle', 'NIO', 'Network.framework', 'WebKit.framework')
        if any(dependency in helper_linked for dependency in forbidden):
            raise SystemExit(f'{name} links a provider or network dependency')
        subprocess.run(['codesign', '--verify', '--strict', str(helper)], check=True)
        helper_binaries.append(helper_binary)

    environment = dict(os.environ)
    # The existing test-host guard skips providers and leaves other app copies
    # running. dyld still loads the exact packaged Release binary and libraries.
    environment['XCTestConfigurationFilePath'] = 'package-startup-check'
    with tempfile.TemporaryFile() as log:
        process = subprocess.Popen([str(binary)], env=environment, stdout=log, stderr=log)
        helper_processes = []
        try:
            time.sleep(3)
            if process.poll() is not None:
                log.seek(0)
                sys.stderr.write(log.read().decode('utf-8', errors='replace'))
                raise SystemExit(f'Packaged app exited during startup: {process.returncode}')

            with tempfile.TemporaryDirectory(prefix='codenotch-dock-state-') as state:
                session = str(uuid.uuid4())
                for helper_binary in helper_binaries:
                    helper_processes.append(subprocess.Popen([
                        str(helper_binary),
                        '--codenotch-session', session,
                        '--codenotch-parent', str(process.pid),
                        '--codenotch-state', state,
                    ], stdout=log, stderr=log))
                time.sleep(3)
                failed = [child for child in helper_processes if child.poll() is not None]
                if failed:
                    raise SystemExit(f'{len(failed)} packaged Dock helper(s) exited during startup')

                stop(process)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and any(child.poll() is None for child in helper_processes):
                    time.sleep(0.05)
                survivors = [child for child in helper_processes if child.poll() is None]
                if survivors:
                    raise SystemExit(f'{len(survivors)} Dock helper(s) survived the parent exit')

            print('PASS: ZIP extraction, signatures, minimal Dock helpers, startup, and parent-exit lifecycle')
        finally:
            for child in helper_processes:
                stop(child)
            stop(process)
