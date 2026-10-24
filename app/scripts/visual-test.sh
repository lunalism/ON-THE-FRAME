#!/bin/zsh
# 진행 카드·완료 시트 시각 자체 검사(Debug 빌드). 생성 fixture otf-A·otf-B만, 짧은 내보내기.
# 결과 visual-result.json과 PNG(<실행 폴더>/visual/)는 KEEP=1이면 남긴다(사람이 보는 용도).
set -euo pipefail
source "${0:A:h}/derived-data.sh"   # cd 앞에서(상대 경로로 부를 때 ${0:A}가 cd 뒤 위치로 풀리지 않게)
cd "${0:A:h}/.."
APP=${APP:-$OTF_DERIVED_DATA/Build/Products/Debug/OnTheFrame.app}
APP=${APP:A}   # 절대 경로(APP를 상대 경로로 줘도 됨)
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
DEV=Engine/.build/debug/otf-dev
[[ -f .build/test-work/fixtures/otf-A.mp4 ]] || $DEV fixtures .build/test-work/fixtures
RUN=selftest-work/visual-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
cp -c .build/test-work/fixtures/otf-A.mp4 .build/test-work/fixtures/otf-B.mp4 $RUN/sources/
( open -n -W -a "$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFVisualTest ) &
OPENPID=$!
for i in {1..240}; do [[ -f $RUN/visual-result.json ]] && break; sleep 1; done
wait $OPENPID || true
[[ -f $RUN/visual-result.json ]] || { echo "no result (timeout)"; exit 1 }
set +e   # 판정이 실패해도 아래 정리(실행 폴더 지우기)를 한다
python3 - "$RUN/visual-result.json" <<'PY'
import json, sys
cs = json.load(open(sys.argv[1]))
for c in cs: print("PASS" if c["pass"] else "FAIL", c["name"], "—", c["detail"])
bad = [c for c in cs if not c["pass"]]
print("OVERALL PASS" if not bad else "OVERALL FAIL")
sys.exit(1 if bad else 0)
PY
RC=$?
cp $RUN/visual-result.json selftest-work/last-visual-result.json
echo "run folder: $RUN"
[[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
exit $RC
