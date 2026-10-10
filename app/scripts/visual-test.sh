#!/bin/zsh
# 진행 카드·완료 시트 시각 자체 검사(Debug 빌드). 생성 fixture otf-A·otf-B만, 짧은 내보내기.
# 결과 visual-result.json과 PNG(<실행 폴더>/visual/)는 KEEP=1이면 남긴다(사람이 보는 용도).
set -euo pipefail
cd "${0:A:h}/.."
APP=.build/DerivedData/Build/Products/Debug/OnTheFrame.app
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
DEV=Engine/.build/debug/otf-dev
[[ -f .build/test-work/fixtures/otf-A.mp4 ]] || $DEV fixtures .build/test-work/fixtures
RUN=selftest-work/visual-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
cp -c .build/test-work/fixtures/otf-A.mp4 .build/test-work/fixtures/otf-B.mp4 $RUN/sources/
( open -n -W -a "$PWD/$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFVisualTest ) &
OPENPID=$!
for i in {1..240}; do [[ -f $RUN/visual-result.json ]] && break; sleep 1; done
wait $OPENPID || true
[[ -f $RUN/visual-result.json ]] || { echo "no result (timeout)"; exit 1 }
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
