#!/bin/zsh
# 끌기 중 편집 보호 자체 검사(Debug, 2026-10-11, CP-01). 실제 마우스 이벤트·실제 문맥 메뉴 추적, 끝나지 않은 끌기 상태의 편집 경로.
# 생성 fixture(otf-TA)만, 저장하지 않는다. 앱 경로를 APP으로 바꿀 수 있다. PICK=1이면 끌기 중 메뉴의 "연결 해제"를 실제로 실행한다(재현용).
set -euo pipefail
cd "${0:A:h}/.."
APP=${APP:-.build/DerivedData/Build/Products/Debug/OnTheFrame.app}
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
Engine/.build/debug/otf-dev fixtures .build/test-work/fixtures > /dev/null
RUN=selftest-work/gestureguard-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
cp -c .build/test-work/fixtures/otf-TA.mp4 $RUN/sources/
( open -n -W -a "$PWD/$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFGestureGuardTest ${PICK:+-OTFGestureGuardPick} ) &
OPENPID=$!
for i in {1..300}; do [[ -f $RUN/gestureguard-result.json ]] && break; kill -0 $OPENPID 2>/dev/null || break; sleep 1; done
wait $OPENPID || true
if [[ ! -f $RUN/gestureguard-result.json ]]; then
  echo "no result (app ended without result — crashed or timed out). progress:"
  cat $RUN/gestureguard-progress.txt 2>/dev/null || echo "(no progress file)"
  [[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
  exit 1
fi
cp $RUN/gestureguard-result.json selftest-work/last-gestureguard-result.json
python3 - $RUN/gestureguard-result.json <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
for c in r: print("PASS" if c["pass"] else "FAIL", c["name"], ("— "+c["detail"][:400]) if c["detail"] else "")
f=[c for c in r if not c["pass"]]
print("OVERALL PASS" if not f else f"OVERALL FAIL ({len(f)})")
sys.exit(1 if f else 0)
PY
RC=$?
[[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
exit $RC
