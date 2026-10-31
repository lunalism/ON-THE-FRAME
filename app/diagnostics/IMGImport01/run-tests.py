#!/usr/bin/env python3
"""Compile actual app sources with a standalone test main; no app/UI launch.
Usage: python3 run-tests.py <debug|release> <fresh evidence directory>
Run the matching bounded SwiftPM tests first (Release with -enable-testing).
"""
import os, pathlib, subprocess, sys
repo = pathlib.Path(__file__).resolve().parents[3]
configuration, output = sys.argv[1:]
gate_only = os.environ.get('OTF_IMPORT_GATE_ONLY') == '1'
assert configuration in ('debug', 'release')
out = pathlib.Path(output).resolve()
out.mkdir(parents=True, exist_ok=False)
build = pathlib.Path.home() / 'Library/Developer/ON-THE-FRAME/IMG1A-build' / configuration
# The test main replaces only the @main attribute in a disposable copy.
app = repo / 'app/OnTheFrame'
entry = out / 'OnTheFrameApp.swift'
original = (app / entry.name).read_text()
assert original.count('@main') == 1
entry.write_text(original.replace('@main', '', 1))
sources = [str(p) for p in sorted(app.rglob('*.swift')) if p.name != entry.name]
sources += [str(entry), str(pathlib.Path(__file__).with_name('GateDisabledAppTests.swift' if gate_only else 'ImageImportAppTests.swift'))]
objects = []
for target in ('OnTheFrameEngine', 'OTFDevSupport', 'E2Core', 'E1Core'):
    product = build / (target + '.o')
    objects += [str(product)] if product.exists() else [str(p) for p in (build / (target + '.build')).glob('*.o')]
assert objects
command = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-strict-concurrency=complete',
           '-target', 'arm64-apple-macosx15.0', '-DOTF_SAFETY_TESTS', '-DOTF_PERSIST_TESTS', '-DOTF_IMAGE_IMPORT', '-whole-module-optimization',
           '-Onone' if configuration == 'debug' else '-O',
           '-I', str(build), '-I', str(build / 'Modules')]
if gate_only: command.remove('-DOTF_IMAGE_IMPORT')
if configuration == 'debug':
    command += ['-DDEBUG']
command += sources + objects + ['-o', str(out / 'safety-tests')]
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
legacy = out / 'legacy-fixtures'
legacy.mkdir()
for name in ('otf-A.mp4', 'aud-wav48s.wav'):
    __import__('shutil').copy2(repo / 'app/.build/test-work/fixtures' / name, legacy / name)
env['OTF_IMPORT_LEGACY_FIXTURES'] = str(legacy)

(out / 'command.txt').write_text('\n'.join(command))
with (out / 'compile.log').open('w') as log:
    result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, env=env)
print('compile exit', result.returncode, flush=True)
if result.returncode:
    sys.exit(result.returncode)
for mode in (('enabled',) if gate_only else ('disabled', 'enabled')):
    args = [str(out / 'safety-tests'), str(out / ('fixtures-'+mode)), '-OTFLayoutSuite', 'dev.ontheframe.import-test.'+__import__('uuid').uuid4().hex]
    if mode == 'enabled': args += ['-OTFEnableImageImport']
    with (out / ('run-'+mode+'.log')).open('w') as log:
        result = subprocess.run(args, stdout=log, stderr=subprocess.STDOUT, env=env, timeout=60)
    print(mode, 'app tests exit', result.returncode, flush=True)
    if result.returncode: sys.exit(result.returncode)
