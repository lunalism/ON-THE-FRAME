#!/bin/zsh
# 타임라인 클립 복사·붙여넣기 자체 검사(Debug, 2026-10-11). 실제 키 이벤트·편집 메뉴·실행 취소·프로젝트 바꾸기.
# 생성 fixture(otf-TA)만, 저장하지 않는다. 앱 경로를 APP으로 바꿀 수 있다.
set -euo pipefail
cd "${0:A:h}/.."
APP=${APP:-.build/DerivedData/Build/Products/Debug/OnTheFrame.app}
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
Engine/.build/debug/otf-dev fixtures .build/test-work/fixtures > /dev/null
RUN=selftest-work/copypaste-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
cp -c .build/test-work/fixtures/otf-TA.mp4 $RUN/sources/
( open -n -W -a "$PWD/$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFCopyPasteTest ) &
OPENPID=$!
for i in {1..300}; do [[ -f $RUN/copypaste-result.json ]] && break; sleep 1; done
wait $OPENPID || true
[[ -f $RUN/copypaste-result.json ]] || { echo "no result (timeout)"; exit 1 }
cp $RUN/copypaste-result.json selftest-work/last-copypaste-result.json
python3 - $RUN/copypaste-result.json <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
for c in r: print("PASS" if c["pass"] else "FAIL", c["name"], ("— "+(c["detail"] if c["name"]=="log" else c["detail"][:300])) if c["detail"] else "")
f=[c for c in r if not c["pass"]]
print("OVERALL PASS" if not f else f"OVERALL FAIL ({len(f)})")
sys.exit(1 if f else 0)
PY
RC=$?
[[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
exit $RC
