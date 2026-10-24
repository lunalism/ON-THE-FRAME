#!/bin/zsh
# 여러 레인·소리 파일 자체 검사(A-014, Debug 빌드). 생성 fixture otf-TA·otf-TB와 소리 파일 aud-*(WAV·AIFF·AAC·ALAC), reject-4ch.wav만.
# 앱이 레인 추가·순서·이름·삭제, 레인 사이 놓기·끌기, 음소거·음량, 저장·다시 열기(형식 2)·형식 1 열기·재연결을 검사하고,
# 다시 연 프로젝트의 내보내기를 otf-dev verify-multilane이 독립 기대값(가장 위 영상 레인, 클릭 위치, 음 진폭)으로 판정한다.
set -euo pipefail
source "${0:A:h}/derived-data.sh"   # cd 앞에서(상대 경로로 부를 때 ${0:A}가 cd 뒤 위치로 풀리지 않게)
cd "${0:A:h}/.."
APP=${APP:-$OTF_DERIVED_DATA/Build/Products/Debug/OnTheFrame.app}
APP=${APP:A}   # 절대 경로(APP를 상대 경로로 줘도 됨)
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
DEV=Engine/.build/debug/otf-dev
$DEV fixtures .build/test-work/fixtures > /dev/null   # 없는 fixture만 만든다
RUN=selftest-work/multilane-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
for f in otf-TA.mp4 otf-TB.mp4 aud-wav48s.wav aud-aiff441m.aiff aud-aac48s.m4a aud-alac441s.m4a reject-4ch.wav; do cp -c .build/test-work/fixtures/$f $RUN/sources/; done
( open -n -W -a "$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFMultiLaneTest ) &
OPENPID=$!
for i in {1..300}; do [[ -f $RUN/multilane-result.json ]] && break; sleep 1; done
wait $OPENPID || true
[[ -f $RUN/multilane-result.json ]] || { echo "no result (timeout)"; exit 1 }
set +e
$DEV verify-multilane $RUN
RC=$?
cp $RUN/multilane-result.json selftest-work/last-multilane-result.json
[[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
exit $RC
