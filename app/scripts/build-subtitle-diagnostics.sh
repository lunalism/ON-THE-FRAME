#!/bin/zsh
# Explicit Debug diagnostic app; normal OnTheFrame builds do not contain these modes.
# Bounded to the IMG-BUILD-01 compiler budget; logs and outputs are preserved.
# Original subtitle checks are retained; resource-limit failures are not build PASS.
set -euo pipefail
source "${0:A:h}/derived-data.sh"
cd "${0:A:h}/.."
python3 - "$PWD" "$OTF_DERIVED_DATA" <<'PY'
import datetime, os, pathlib, sys, uuid
app, derived = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(app / 'diagnostics/IMGBuild01'))
from compiler_budget import run
out = app / 'selftest-work' / ('subtitle-diagnostics-build-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8])
command = ['xcodebuild', '-project', 'OnTheFrame.xcodeproj', '-scheme', 'OnTheFrameSubtitleDiagnostics',
           '-configuration', 'Debug', '-destination', 'platform=macOS,arch=arm64',
           '-derivedDataPath', str(derived), '-jobs', '1', 'COMPILER_INDEX_STORE_ENABLE=NO', 'SWIFT_ENABLE_BATCH_MODE=NO', 'OTHER_SWIFT_FLAGS=$(inherited) -j1', 'build']
result = run(command, out, cwd=app, env=os.environ.copy(), marker=str(derived), seconds=300)
print(result)
print('evidence:', out)
print('app:', derived / 'Build/Products/Debug/OnTheFrameSubtitleDiagnostics.app')
sys.exit(0 if result['exit'] == 0 and not result['safety_stop'] else 1)
PY
