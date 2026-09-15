#!/usr/bin/env python3
"""Verify the shipped ZIP and start its exact binary without polling accounts."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

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
    environment = dict(os.environ)
    # The existing test-host guard skips providers and leaves other app copies
    # running. dyld still loads the exact packaged Release binary and libraries.
    environment['XCTestConfigurationFilePath'] = 'package-startup-check'
    with tempfile.TemporaryFile() as log:
        process = subprocess.Popen([str(binary)], env=environment, stdout=log, stderr=log)
        try:
            time.sleep(3)
            if process.poll() is not None:
                log.seek(0)
                sys.stderr.write(log.read().decode('utf-8', errors='replace'))
                raise SystemExit(f'Packaged app exited during startup: {process.returncode}')
            print('PASS: ZIP extraction, no Sparkle dependency, signature, and packaged Release startup')
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
