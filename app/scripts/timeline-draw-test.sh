#!/bin/zsh
# 타임라인 그리기 범위 자체 검사(Debug 빌드, 2026-10-23). 생성 fixture otf-TA만. 보이는 영역만 그린 그림 = 전체를 돌며 그린 그림(화소 비교).
# 입력 이벤트·초점을 쓰지 않으므로 앱을 뒤에서 연다(open -g).
set -euo pipefail
source "${0:A:h}/derived-data.sh"   # cd 앞에서(상대 경로로 부를 때 ${0:A}가 cd 뒤 위치로 풀리지 않게)
cd "${0:A:h}/.."
APP=${APP:-$OTF_DERIVED_DATA/Build/Products/Debug/OnTheFrame.app}
APP=${APP:A}   # 절대 경로(APP를 상대 경로로 줘도 됨)
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
Engine/.build/debug/otf-dev fixtures .build/test-work/fixtures > /dev/null
RUN=selftest-work/timelinedraw-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
cp -c .build/test-work/fixtures/otf-TA.mp4 $RUN/sources/
( open -g -n -W -a "$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFTimelineDrawTest ) &
OPENPID=$!
for i in {1..300}; do [[ -f $RUN/timeline-draw-result.json ]] && break; sleep 1; done
wait $OPENPID || true
[[ -f $RUN/timeline-draw-result.json ]] || { echo "no result (timeout)"; exit 1 }
cp $RUN/timeline-draw-result.json selftest-work/last-timeline-draw-result.json
set +e
python3 - $RUN/timeline-draw-result.json <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
for c in r: print("PASS" if c["pass"] else "FAIL", c["name"], ("— "+c["detail"]) if c["detail"] else "")
f=[c for c in r if not c["pass"]]
print("OVERALL PASS" if not f else f"OVERALL FAIL ({len(f)})")
sys.exit(1 if f else 0)
PY
RC=$?
[[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
exit $RC
