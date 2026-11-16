#!/bin/zsh
# 프로젝트 열기 ↔ 저장하지 않은 변경 확인 ↔ 저장 흐름 자체 검사(Debug, 2026-10-11 소유자 보고). 실제 메뉴·확인 시트·저장 패널·열기 패널.
# 생성 fixture(otf-A)만, 일회용 프로젝트는 실행 폴더(out)에만 저장한다. 앱 경로를 APP으로 바꿀 수 있다.
set -euo pipefail
source "${0:A:h}/derived-data.sh"   # cd 앞에서(상대 경로로 부를 때 ${0:A}가 cd 뒤 위치로 풀리지 않게)
cd "${0:A:h}/.."
APP=${APP:-$OTF_DERIVED_DATA/Build/Products/Debug/OnTheFrame.app}
APP=${APP:A}   # 절대 경로(APP를 상대 경로로 줘도 됨)
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
Engine/.build/debug/otf-dev fixtures .build/test-work/fixtures > /dev/null
RUN=selftest-work/openflow-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
cp -c .build/test-work/fixtures/otf-A.mp4 $RUN/sources/
START=$(date "+%Y-%m-%d %H:%M:%S")
( open -n -W -a "$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFOpenFlowTest ) &
OPENPID=$!
for i in {1..300}; do [[ -f $RUN/openflow-result.json ]] && break; sleep 1; done
wait $OPENPID || true
[[ -f $RUN/openflow-result.json ]] || { echo "no result (timeout)"; exit 1 }
cp $RUN/openflow-result.json selftest-work/last-openflow-result.json
echo "--- trace (open/save flow)"
/usr/bin/log show --info --start "$START" --style compact --predicate 'subsystem == "dev.ontheframe.app" AND category == "trace" AND eventMessage BEGINSWITH "open"' 2>/dev/null | sed -E 's/^[0-9-]+ ([0-9:.]+) .*\[dev.ontheframe.app:trace\] /\1 /' | grep -v "^Timestamp" | tail -40 || true
python3 - $RUN/openflow-result.json <<'PY'
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
