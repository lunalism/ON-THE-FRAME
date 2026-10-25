#!/bin/zsh
# 스펙트럼 레인 타임라인 표시 자체 검사(Debug, 2026-10-25, SP-1A 2A). 레인 순서·배치·빈 레인·읽기 전용 항목·확대·단축키·안전 장치.
# 생성 fixture(otf-TA)만. 실행 폴더 안에만 쓴다(형식 8 시험 파일 포함). 앱 경로를 APP으로 바꿀 수 있다.
set -euo pipefail
source "${0:A:h}/derived-data.sh"   # cd 앞에서(상대 경로로 부를 때 ${0:A}가 cd 뒤 위치로 풀리지 않게)
cd "${0:A:h}/.."
APP=${APP:-$OTF_DERIVED_DATA/Build/Products/Debug/OnTheFrame.app}
APP=${APP:A}   # 절대 경로(APP를 상대 경로로 줘도 됨)
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
Engine/.build/debug/otf-dev fixtures .build/test-work/fixtures > /dev/null
RUN=selftest-work/spectrum-lane-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
cp -c .build/test-work/fixtures/otf-TA.mp4 $RUN/sources/
( open -n -W -a "$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFSpectrumLaneTest ) &
OPENPID=$!
for i in {1..300}; do [[ -f $RUN/spectrum-lane-result.json ]] && break; sleep 1; done
wait $OPENPID || true
[[ -f $RUN/spectrum-lane-result.json ]] || { echo "no result (timeout)"; exit 1 }
cp $RUN/spectrum-lane-result.json selftest-work/last-spectrum-lane-result.json
python3 - $RUN/spectrum-lane-result.json <<'PY'
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
