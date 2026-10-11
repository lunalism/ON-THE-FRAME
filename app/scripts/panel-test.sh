#!/bin/zsh
# 왼쪽 패널 탭(미디어·클립 조정)·클립 조정 칸·오른쪽 읽기 전용 정보 자체 검사(Debug 빌드). 생성 fixture otf-TA·otf-TB·aud-wav48s만.
set -euo pipefail
cd "${0:A:h}/.."
APP=${APP:-.build/DerivedData/Build/Products/Debug/OnTheFrame.app}
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
Engine/.build/debug/otf-dev fixtures .build/test-work/fixtures > /dev/null
RUN=selftest-work/panel-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
for f in otf-TA.mp4 otf-TB.mp4 aud-wav48s.wav; do cp -c .build/test-work/fixtures/$f $RUN/sources/; done
( open -n -W -a "$PWD/$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFPanelTest ) &
OPENPID=$!
for i in {1..180}; do [[ -f $RUN/panel-result.json ]] && break; sleep 1; done
wait $OPENPID || true
[[ -f $RUN/panel-result.json ]] || { echo "no result (timeout)"; exit 1 }
cp $RUN/panel-result.json selftest-work/last-panel-result.json
python3 - $RUN/panel-result.json <<'PY'
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
