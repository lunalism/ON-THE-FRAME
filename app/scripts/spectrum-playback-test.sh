#!/bin/zsh
# Unique disposable copies only; retain all evidence. Never regenerate shared manual fixtures.
set -euo pipefail
source "${0:A:h}/derived-data.sh"
cd "${0:A:h}/.."
APP=${APP:-$OTF_DERIVED_DATA/Build/Products/Debug/OnTheFrame.app}
BINARY="$APP/Contents/MacOS/OnTheFrame"
[[ -x "$BINARY" ]] && { /usr/bin/grep -a -q -- '-OTFSpectrumPlaybackTest' "$BINARY" ||
  { [[ -f "$BINARY.debug.dylib" ]] && /usr/bin/grep -a -q -- '-OTFSpectrumPlaybackTest' "$BINARY.debug.dylib"; }; } || {
  echo "FAIL: build the current Debug app before running this test"; exit 2
}
RUN=$(mktemp -d "$PWD/selftest-work/spectrum-playback-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
mkdir -p "$RUN/sources"
python3 - "$RUN/sources/aud-wav48s.wav" <<'PYWAV'
import array, math, sys, wave
samples = array.array('h')
for n in range(6 * 48000):
    value = round(0.4 * 32767 * math.sin(2 * math.pi * 440 * n / 48000))
    samples.extend((value, value))
with wave.open(sys.argv[1], 'wb') as output:
    output.setnchannels(2); output.setsampwidth(2); output.setframerate(48000)
    output.writeframes(samples.tobytes())
PYWAV
cp "$RUN/sources/aud-wav48s.wav" "$RUN/sources/relinked.wav"
echo "Evidence: $RUN"
open -n -a "$APP" "$RUN" --args -OTFLayoutSuite "dev.ontheframe.test.lifecycle.$(uuidgen)" -OTFLayoutReset -OTFSpectrumPlaybackTest
for i in {1..240}; do
  if [[ -f "$RUN/spectrum-playback-result.json" ]]; then
    python3 - "$RUN/spectrum-playback-result.json" <<'PY'
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
echo "FAIL: no result within 240 s; test app left intact for diagnosis"
exit 1
