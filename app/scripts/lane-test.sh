#!/bin/zsh
# 레인·연결·레인 이름 자체 검사(A-012, Debug 빌드). 생성 fixture otf-TA·otf-TB(연속음+클릭)·otf-hevc(소리 없음).
# 앱이 합성 마우스·키 이벤트로 편집하고, 마지막 내보내기를 otf-dev verify-lanes가 독립 기대값으로 판정한다.
set -euo pipefail
cd "${0:A:h}/.."
APP=${APP:-.build/DerivedData/Build/Products/Debug/OnTheFrame.app}
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
DEV=Engine/.build/debug/otf-dev
[[ -f .build/test-work/fixtures/otf-TA.mp4 ]] || $DEV fixtures .build/test-work/fixtures
RUN=selftest-work/lane-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
for f in otf-TA.mp4 otf-TB.mp4 otf-hevc.mp4; do cp -c .build/test-work/fixtures/$f $RUN/sources/; done
( open -n -W -a "$PWD/$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout ${=EXTRA_ARGS:-} -OTFLaneTest ) &
OPENPID=$!
for i in {1..240}; do [[ -f $RUN/lane-result.json ]] && break; sleep 1; done
wait $OPENPID || true
[[ -f $RUN/lane-result.json ]] || { echo "no result (timeout)"; exit 1 }
set +e
$DEV verify-lanes $RUN
RC=$?
cp $RUN/lane-result.json selftest-work/last-lane-result.json
[[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
exit $RC
