#!/bin/zsh
# 소리 클립 음량·음소거·페이드 자체 검사(Debug 빌드). 생성 fixture aud-steady48s·otf-TB만.
set -euo pipefail
cd "${0:A:h}/.."
APP=${APP:-.build/DerivedData/Build/Products/Debug/OnTheFrame.app}
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
Engine/.build/debug/otf-dev fixtures .build/test-work/fixtures > /dev/null
RUN=selftest-work/clipaudio-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
for f in aud-steady48s.wav otf-TB.mp4; do cp -c .build/test-work/fixtures/$f $RUN/sources/; done
( open -n -W -a "$PWD/$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFClipAudioTest ) &
OPENPID=$!
for i in {1..180}; do [[ -f $RUN/clipaudio-result.json ]] && break; sleep 1; done
wait $OPENPID || true
[[ -f $RUN/clipaudio-result.json ]] || { echo "no result (timeout)"; exit 1 }
cp $RUN/clipaudio-result.json selftest-work/last-clipaudio-result.json
python3 - $RUN/clipaudio-result.json <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
for c in r: print("PASS" if c["pass"] else "FAIL", c["name"], ("— "+c["detail"][:300]) if c["detail"] else "")
f=[c for c in r if not c["pass"]]
print("OVERALL PASS" if not f else f"OVERALL FAIL ({len(f)})")
sys.exit(1 if f else 0)
PY
RC=$?
[[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
exit $RC
