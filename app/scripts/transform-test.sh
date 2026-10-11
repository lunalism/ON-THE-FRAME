#!/bin/zsh
# 영상 크기·위치 자체 검사(A-015, Debug 빌드). 생성 단색 판 fixture(plate-blue 1920×1080, plate-red 640×480)만.
# 앱이 프리뷰 편집 테두리 끌기(옮기기·모서리 크기·Esc)·정보 패널 값·실행 취소·자르기·저장·다시 열기를 검사하고,
# 테두리를 띄운 채 내보낸 파일을 otf-dev verify-overlay가 독립 기대값(좌표계 정의에서 계산한 사각형)으로 격자 판정한다.
set -euo pipefail
cd "${0:A:h}/.."
APP=${APP:-.build/DerivedData/Build/Products/Debug/OnTheFrame.app}
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
DEV=Engine/.build/debug/otf-dev
$DEV fixtures .build/test-work/fixtures > /dev/null   # 없는 fixture만 만든다
RUN=selftest-work/transform-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
for f in plate-blue-1920x1080.mp4 plate-red-640x480.mp4; do cp -c .build/test-work/fixtures/$f $RUN/sources/; done
( open -n -W -a "$PWD/$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset ${=EXTRA_ARGS:-} -OTFTransformTest ) &
OPENPID=$!
for i in {1..240}; do [[ -f $RUN/transform-result.json ]] && break; sleep 1; done
wait $OPENPID || true
[[ -f $RUN/transform-result.json ]] || { echo "no result (timeout)"; exit 1 }
set +e
$DEV verify-overlay $RUN
RC=$?
cp $RUN/transform-result.json selftest-work/last-transform-result.json
[[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
exit $RC
