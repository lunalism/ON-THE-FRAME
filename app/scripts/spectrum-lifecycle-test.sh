#!/bin/zsh
# Unique disposable copies only; retain all evidence. Never regenerate shared manual fixtures.
set -euo pipefail
source "${0:A:h}/derived-data.sh"
cd "${0:A:h}/.."
APP=${APP:-$OTF_DERIVED_DATA/Build/Products/Debug/OnTheFrame.app}
BINARY="$APP/Contents/MacOS/OnTheFrame"
[[ -x "$BINARY" ]] && { /usr/bin/grep -a -q -- '-OTFSpectrumLifecycleTest' "$BINARY" ||
  { [[ -f "$BINARY.debug.dylib" ]] && /usr/bin/grep -a -q -- '-OTFSpectrumLifecycleTest' "$BINARY.debug.dylib"; }; } || {
  echo "FAIL: build the current Debug app before running this test"; exit 2
}
RUN=$(mktemp -d "$PWD/selftest-work/spectrum-lifecycle-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
mkdir -p "$RUN/sources"
FIXTURE="$PWD/.build/test-work/fixtures/aud-wav48s.wav"
[[ -f "$FIXTURE" ]] || { echo "FAIL: missing generated fixture: $FIXTURE"; exit 2; }
cp "$FIXTURE" "$RUN/sources/aud-wav48s.wav"
cp "$FIXTURE" "$RUN/sources/relinked.wav"
echo "Evidence: $RUN"
open -n -a "$APP" "$RUN" --args -OTFLayoutSuite "dev.ontheframe.test.lifecycle.$(uuidgen)" -OTFLayoutReset -OTFSpectrumLifecycleTest
for i in {1..120}; do
  if [[ -f "$RUN/spectrum-lifecycle-result.json" ]]; then
    python3 - "$RUN/spectrum-lifecycle-result.json" <<'PY'
import json, sys
checks = json.load(open(sys.argv[1]))
for check in checks:
    print('PASS' if check['pass'] else 'FAIL', check['name'], check['detail'])
failures = sum(not c['pass'] for c in checks)
print(f'{len(checks)} checks, {failures} failures')
sys.exit(bool(failures))
PY
    exit $?
  fi
  sleep 1
done
echo "FAIL: no result within 120 s; test app left intact for diagnosis"
exit 1
