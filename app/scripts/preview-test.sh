#!/bin/zsh
# 편집 뒤 프리뷰 갱신 자체 검사(완료 기준 4, Debug 빌드). 생성 fixture otf-A·otf-B만, 내보내기 없음.
# 앱이 고정 재생 헤드의 프리뷰 프레임을 저장하고, otf-dev verify-preview가 화면 코드·검정으로 판정한다.
set -euo pipefail
source "${0:A:h}/derived-data.sh"   # cd 앞에서(상대 경로로 부를 때 ${0:A}가 cd 뒤 위치로 풀리지 않게)
cd "${0:A:h}/.."
APP=${APP:-$OTF_DERIVED_DATA/Build/Products/Debug/OnTheFrame.app}
APP=${APP:A}   # 절대 경로(APP를 상대 경로로 줘도 됨)
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
DEV=Engine/.build/debug/otf-dev
[[ -f .build/test-work/fixtures/otf-A.mp4 ]] || $DEV fixtures .build/test-work/fixtures
RUN=selftest-work/preview-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
cp -c .build/test-work/fixtures/otf-A.mp4 .build/test-work/fixtures/otf-B.mp4 $RUN/sources/
( open -n -W -a "$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFPreviewTest ) &
OPENPID=$!
for i in {1..180}; do [[ -f $RUN/preview-manifest.json ]] && break; sleep 1; done
wait $OPENPID || true
[[ -f $RUN/preview-manifest.json ]] || { echo "no result (timeout)"; exit 1 }
set +e
$DEV verify-preview $RUN
RC=$?
cp $RUN/preview-manifest.json selftest-work/last-preview-manifest.json
[[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
exit $RC
