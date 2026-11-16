#!/usr/bin/env python3
"""Isolated actual PlayerNSView compatibility host; not a signed normal app.
Usage: python3 run-tests.py <debug|release> <fresh evidence directory>
Run the matching bounded SwiftPM tests first (Release with -enable-testing).
"""
import os, pathlib, subprocess, sys
repo = pathlib.Path(__file__).resolve().parents[3]
configuration, output = sys.argv[1:]
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
sources += [str(entry), str(pathlib.Path(__file__).with_name('ProductImagePreviewAppTests.swift'))]
objects = []
for target in ('OnTheFrameEngine', 'OTFDevSupport', 'E2Core', 'E1Core'):
    product = build / (target + '.o')
    objects += [str(product)] if product.exists() else [str(p) for p in (build / (target + '.build')).glob('*.o')]
assert objects
command = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5', '-strict-concurrency=complete',
           '-target', 'arm64-apple-macosx15.0', '-DOTF_SAFETY_TESTS', '-DOTF_PERSIST_TESTS', '-DOTF_PREVIEW_COMPAT_TESTS', '-DOTF_IMAGE_IMPORT', '-whole-module-optimization',
           '-Onone' if configuration == 'debug' else '-O',
           '-I', str(build), '-I', str(build / 'Modules')]
if configuration == 'debug':
    command += ['-DDEBUG']
test_objects = pathlib.Path.home() / 'Library/Developer/ON-THE-FRAME/IMG1A-build/out/Intermediates.noindex/OnTheFrameEngine.build' / configuration.capitalize() / 'OnTheFrameEngineTests-p.build/Objects-normal/arm64'
objects += [str(p) for p in test_objects.glob('*.o') if p.name != 'test_entry_point.o']
if configuration == 'release':
    # Release cross-file specializations also live in this generated object.
    # Keep them; localize ONLY its unused C entry point in a disposable copy.
    import hashlib, json
    entry_object = test_objects / 'test_entry_point.o'
    original_digest = hashlib.sha256(entry_object.read_bytes()).hexdigest()
    local_symbols = out / 'unused-test-main.txt'
    local_symbols.write_text('_main\n')
    localized = out / 'test-support-with-local-main.o'
    result = subprocess.run(['/usr/bin/nmedit', '-R', str(local_symbols), '-o', str(localized), str(entry_object)], capture_output=True, text=True)
    (out / 'test-support-localize.log').write_text(result.stdout + result.stderr)
    if result.returncode: sys.exit(result.returncode)
    def globals_at(path):
        return {line.split()[-1] for line in subprocess.check_output(['/usr/bin/nm', '-g', str(path)], text=True).splitlines() if line.split()}
    before_symbols, after_symbols = globals_at(entry_object), globals_at(localized)
    assert '_main' in before_symbols and '_main' not in after_symbols
    assert before_symbols - {'_main'} == after_symbols
    assert hashlib.sha256(entry_object.read_bytes()).hexdigest() == original_digest
    (out / 'test-support-identity.json').write_text(json.dumps({'original_sha256':original_digest,'original_unchanged':True,'only_localized_global':'_main'}, indent=2))
    objects += [str(localized)]

frameworks='/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks'
libs='/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib'
command += ['-F',frameworks,'-framework','XCTest','-L',libs,'-lXCTestSwiftSupport','-Xlinker','-rpath','-Xlinker',frameworks,'-Xlinker','-rpath','-Xlinker',libs]
command += sources + objects + ['-o', str(out / 'safety-tests')]
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
(out / 'command.txt').write_text('\n'.join(command))
with (out / 'compile.log').open('w') as log:
    result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, env=env)
print('compile exit', result.returncode, flush=True)
if result.returncode:
    sys.exit(result.returncode)
with (out / 'run.log').open('w') as log:
    result = subprocess.run([str(out / 'safety-tests'), str(out / 'fixtures'), '-OTFEnableImageImport', '-OTFLayoutSuite', 'dev.ontheframe.persist-test.'+__import__('uuid').uuid4().hex], stdout=log, stderr=subprocess.STDOUT, env=env, timeout=90)
print('app tests exit', result.returncode)
sys.exit(result.returncode)
