#!/bin/zsh
# 창·편집기 배치 자체 검사(A-012, Debug 빌드). 사용자 설정과 따로 둔 저장소(dev.ontheframe.test.layoutcheck)로 세 번 실행한다:
# first(저장값 지움 → 70% 가운데, 나눔 비율, 나눔선 끌기·저장), restore(되살리기), offscreen(화면 밖 저장값 → 안으로).
set -euo pipefail
source "${0:A:h}/derived-data.sh"   # cd 앞에서(상대 경로로 부를 때 ${0:A}가 cd 뒤 위치로 풀리지 않게)
cd "${0:A:h}/.."
APP=${APP:-$OTF_DERIVED_DATA/Build/Products/Debug/OnTheFrame.app}
APP=${APP:A}   # 절대 경로(APP를 상대 경로로 줘도 됨)
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
RUN=selftest-work/layout-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN
SUITE=dev.ontheframe.test.layoutcheck
run() {   # $1 단계, 나머지: 추가 인수
  local phase=$1; shift
  ( open -n -W -a "$APP" "$PWD/$RUN" --args -OTFLayoutSuite $SUITE -OTFLayoutTest $phase "$@" ) &
  local pid=$!
  for i in {1..60}; do [[ -f $RUN/layout-$phase.json ]] && break; sleep 1; done
  wait $pid || true
  [[ -f $RUN/layout-$phase.json ]] || { echo "no result for $phase"; return 1 }
}
run first -OTFLayoutReset
run restore
run offscreen -OTFLayoutInject "-5000,-4000,9000,7000"
python3 - $RUN <<'PY'
import json, sys, os
bad = 0
for ph in ["first", "restore", "offscreen"]:
    for c in json.load(open(os.path.join(sys.argv[1], f"layout-{ph}.json"))):
        print("PASS" if c["pass"] else "FAIL", ph, c["name"], "—", c["detail"])
        bad += 0 if c["pass"] else 1
print("OVERALL PASS" if bad == 0 else f"OVERALL FAIL ({bad})")
sys.exit(1 if bad else 0)
PY
RC=$?
mkdir -p selftest-work && cat $RUN/layout-*.json > selftest-work/last-layout-result.json
[[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
exit $RC
