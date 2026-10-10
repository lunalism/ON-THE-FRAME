#!/bin/zsh
# 프로젝트 저장·열기 자체 검사(A-013, Debug 빌드). 생성 fixture otf-TA·otf-TB·otf-A·otf-hevc만.
# 앱이 저장·다시 열기·재연결·최근 목록·저장하지 않은 변경 처리를 검사하고, 다시 연 프로젝트의 내보내기를 otf-dev verify-project가 독립 판정한다.
set -euo pipefail
cd "${0:A:h}/.."
APP=${APP:-.build/DerivedData/Build/Products/Debug/OnTheFrame.app}
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
DEV=Engine/.build/debug/otf-dev
[[ -f .build/test-work/fixtures/otf-TA.mp4 ]] || $DEV fixtures .build/test-work/fixtures
RUN=selftest-work/project-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
for f in otf-TA.mp4 otf-TB.mp4 otf-A.mp4 otf-hevc.mp4; do cp -c .build/test-work/fixtures/$f $RUN/sources/; done
( open -n -W -a "$PWD/$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFProjectTest ) &
OPENPID=$!
for i in {1..300}; do [[ -f $RUN/project-result.json ]] && break; sleep 1; done
wait $OPENPID || true
[[ -f $RUN/project-result.json ]] || { echo "no result (timeout)"; exit 1 }
set +e
$DEV verify-project $RUN
RC=$?
cp $RUN/project-result.json selftest-work/last-project-result.json
[[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
exit $RC
