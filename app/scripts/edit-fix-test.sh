#!/bin/zsh
# 2026-10-11 편집 수정 자체 검사(Debug 빌드). 생성 fixture otf-TA·otf-TB·aud-wav48s·plate-blue·plate-red만.
# 앱이 + 추가 위치, 가운데 경계 레인 배치·실행 취소·저장·다시 열기, 확대·스크롤 아래 놓기, 연결된 쌍 끌어 옮기기(붙음·겹침 거부·Esc),
# 변형 끌기 깜박임(이전 경로 재현 → 새 경로 빈 화면 0, 정지 화면 = composition 프레임, 내보내기 일치)을 검사하고,
# 다시 연 프로젝트의 내보내기를 otf-dev verify-editfix가 독립 기대값(가장 위 영상 레인, 소리 클릭 위치)으로 판정한다.
set -euo pipefail
source "${0:A:h}/derived-data.sh"   # cd 앞에서(상대 경로로 부를 때 ${0:A}가 cd 뒤 위치로 풀리지 않게)
cd "${0:A:h}/.."
APP=${APP:-$OTF_DERIVED_DATA/Build/Products/Debug/OnTheFrame.app}
APP=${APP:A}   # 절대 경로(APP를 상대 경로로 줘도 됨)
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
DEV=Engine/.build/debug/otf-dev
$DEV fixtures .build/test-work/fixtures > /dev/null   # 없는 fixture만 만든다
RUN=selftest-work/editfix-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
for f in otf-TA.mp4 otf-TB.mp4 aud-wav48s.wav plate-blue-1920x1080.mp4 plate-red-640x480.mp4; do cp -c .build/test-work/fixtures/$f $RUN/sources/; done
( open -n -W -a "$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFEditFixTest ) &
OPENPID=$!
for i in {1..300}; do [[ -f $RUN/editfix-result.json ]] && break; sleep 1; done
wait $OPENPID || true
[[ -f $RUN/editfix-result.json ]] || { echo "no result (timeout)"; exit 1 }
set +e
$DEV verify-editfix $RUN
RC=$?
cp $RUN/editfix-result.json selftest-work/last-editfix-result.json
[[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
exit $RC
