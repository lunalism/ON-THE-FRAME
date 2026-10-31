#!/usr/bin/env python3
"""Build the original SwiftUI @main app as an isolated ad-hoc sandbox validation bundle.
Uses matching, already-built Debug SwiftPM objects. No native panel automation.
Usage: python3 build-signed-app.py <fresh evidence directory>
This is not an Xcode packaging/signing regression result.
"""
import os, pathlib, plistlib, subprocess, sys
repo = pathlib.Path(__file__).resolve().parents[3]
out = pathlib.Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=False)
app = out / 'ImageImportInternal.app'
contents = app / 'Contents'
(contents / 'MacOS').mkdir(parents=True)
info = plistlib.loads((repo / 'app/Config/Info.plist').read_bytes())
info.update(CFBundleExecutable='OnTheFrame', CFBundleIdentifier='dev.ontheframe.import01-validation',
            CFBundleName='ImageImportInternal', CFBundleDisplayName='ON THE FRAME Internal Image Import',
            LSMinimumSystemVersion='15.0')
(contents / 'Info.plist').write_bytes(plistlib.dumps(info))
build = pathlib.Path.home() / 'Library/Developer/ON-THE-FRAME/IMG1A-build/debug'
objects = []
for target in ('OnTheFrameEngine', 'OTFDevSupport', 'E2Core', 'E1Core'):
    product = build / (target + '.o')
    objects += [str(product)] if product.exists() else [str(p) for p in (build / (target + '.build')).glob('*.o')]
assert objects
sources = [str(p) for p in sorted((repo / 'app/OnTheFrame').rglob('*.swift'))]
cmd = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-strict-concurrency=complete',
       '-target', 'arm64-apple-macosx15.0', '-DDEBUG', '-DOTF_IMAGE_IMPORT',
       '-whole-module-optimization', '-Onone', '-I', str(build), '-I', str(build / 'Modules')]
cmd += sources + objects + ['-o', str(contents / 'MacOS/OnTheFrame')]
(out / 'command.txt').write_text('\n'.join(cmd))
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
with (out / 'compile.log').open('w') as log:
    result = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, env=env, timeout=300)
print('actual SwiftUI app compile exit', result.returncode, flush=True)
if result.returncode: sys.exit(result.returncode)
for name, command in [
    ('sign', ['codesign', '--force', '--sign', '-', '--entitlements', str(repo / 'app/Config/OnTheFrame.entitlements'), str(app)]),
    ('verify', ['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app)]),
    ('identity', ['codesign', '-dv', '--verbose=4', str(app)]),
    ('entitlements', ['codesign', '-d', '--entitlements', '-', str(app)])]:
    result = subprocess.run(command, capture_output=True, text=True)
    (out / (name + '.log')).write_text(result.stdout + result.stderr)
    print(name, 'exit', result.returncode, flush=True)
    if result.returncode: sys.exit(result.returncode)
print('APP', app)
