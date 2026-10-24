#!/bin/zsh
# A-010 프레임 0 불일치 진단(Debug 빌드). 30 fps가 아닌 생성 fixture 5개로 원래 실패 타임라인을 앱에 올리고,
# 첫 탐색 뒤 비디오 출력·AVPlayerLayer 표시 버퍼를 기록해 otf-dev verify-layer로 판정한다. 원시 프레임은 판정 뒤 지운다.
set -euo pipefail
source "${0:A:h}/derived-data.sh"   # cd 앞에서(상대 경로로 부를 때 ${0:A}가 cd 뒤 위치로 풀리지 않게)
cd "${0:A:h}/.."
APP=${APP:-$OTF_DERIVED_DATA/Build/Products/Debug/OnTheFrame.app}
APP=${APP:A}   # 절대 경로(APP를 상대 경로로 줘도 됨)
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
DEV=Engine/.build/debug/otf-dev
[[ -f .build/test-work/fixtures/otf-P25.mp4 ]] || $DEV fixtures .build/test-work/fixtures
RUN=selftest-work/layerdiag-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
for f in otf-N2997.mp4 otf-P25.mp4 otf-VFR.mp4 otf-F23976.mp4 otf-H5994.mov; do cp -c .build/test-work/fixtures/$f $RUN/sources/; done
( open -n -W -a "$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayerDiag ) &
OPENPID=$!
for i in {1..180}; do [[ -f $RUN/layer-manifest.json ]] && break; sleep 1; done
wait $OPENPID || true
[[ -f $RUN/layer-manifest.json ]] || { echo "no result (timeout)"; exit 1 }
$DEV verify-layer $RUN
mkdir -p .build/test-work/diagnostics
cp $RUN/layer-result.json .build/test-work/diagnostics/${RUN:t}-layer-result.json
rm -rf $RUN/layerdiag $RUN/sources
[[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
