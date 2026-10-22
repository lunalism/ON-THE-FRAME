#!/bin/zsh
# 자막 자체 검사(Debug, 2026-10-22). 실제 키·마우스 이벤트·글 칸·타임라인 메뉴·저장/다시 열기·프리뷰 층 상태·내보내기.
# 생성 fixture(otf-TA)만, 저장·내보내기는 일회용 폴더에만. 앱 경로를 APP으로 바꿀 수 있다.
set -euo pipefail
cd "${0:A:h}/.."
APP=${APP:-.build/DerivedData/Build/Products/Debug/OnTheFrame.app}
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
Engine/.build/debug/otf-dev fixtures .build/test-work/fixtures > /dev/null
RUN=selftest-work/subtitle-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
cp -c .build/test-work/fixtures/otf-TA.mp4 $RUN/sources/
( open -n -W -a "$PWD/$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFSubtitleTest ) &
OPENPID=$!
for i in {1..400}; do [[ -f $RUN/subtitle-result.json ]] && break; sleep 1; done
wait $OPENPID || true
[[ -f $RUN/subtitle-result.json ]] || { echo "no result (timeout)"; exit 1 }
cp $RUN/subtitle-result.json selftest-work/last-subtitle-result.json
python3 - $RUN/subtitle-result.json <<'PY'
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
