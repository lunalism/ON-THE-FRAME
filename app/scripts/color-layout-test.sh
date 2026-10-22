#!/bin/zsh
# 자막 색 칸 배치 검사(Debug, 2026-10-23): 패널 폭 160·200·280 × 밝은·어두운 모양 그림과 조작 자리. 결과 폴더를 남긴다(그림 확인용, 일회용).
set -euo pipefail
cd "${0:A:h}/.."
APP=${APP:-.build/DerivedData/Build/Products/Debug/OnTheFrame.app}
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
RUN=selftest-work/colorlayout-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN
( open -n -W -a "$PWD/$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFColorLayoutTest ) &
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
