#!/bin/zsh
# 자막 색 칸 배치 검사(Debug, 2026-10-23): 패널 폭 160·200·280 × 밝은·어두운 모양 그림과 조작 자리. 결과 폴더를 남긴다(그림 확인용, 일회용).
set -euo pipefail
source "${0:A:h}/derived-data.sh"   # cd 앞에서(상대 경로로 부를 때 ${0:A}가 cd 뒤 위치로 풀리지 않게)
cd "${0:A:h}/.."
APP=${APP:-$OTF_DERIVED_DATA/Build/Products/Debug/OnTheFrame.app}
APP=${APP:A}   # 절대 경로(APP를 상대 경로로 줘도 됨)
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
RUN=selftest-work/colorlayout-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN
( open -n -W -a "$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFColorLayoutTest ) &
OPENPID=$!
for i in {1..120}; do [[ -f $RUN/colorlayout-result.json ]] && break; sleep 1; done
wait $OPENPID || true
[[ -f $RUN/colorlayout-result.json ]] || { echo "no result (timeout)"; exit 1 }
echo "folder: $RUN"
python3 - $RUN/colorlayout-result.json <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
for c in r: print("PASS" if c["pass"] else "FAIL", c["name"], "—", c["detail"][:400])
f=[c for c in r if not c["pass"]]
print("OVERALL PASS" if not f else f"OVERALL FAIL ({len(f)})")
sys.exit(1 if f else 0)
PY
