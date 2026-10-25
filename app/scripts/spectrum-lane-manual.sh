#!/bin/zsh
# 스펙트럼 레인 소유자 화면 확인(Debug, 2026-10-26, SP-1A 2A). 생성 fixture(otf-TA)만 쓰고 selftest-work/manual-spectrum-lane 안에만 만든다.
# 앱이 메모리 안 타임라인(자막·빈 스펙트럼·스펙트럼 항목 셋·영상·오디오)을 넣고 창을 열어 둔다. 저장·내보내기·열기 없음.
# 따로 둔 설정 저장소(-OTFLayoutSuite)를 써서 사용자의 창 배치·최근 목록을 건드리지 않는다. 다시 실행하면 이 폴더만 새로 만든다.
# 앱 경로를 APP으로 바꿀 수 있다. 창을 닫거나 ⌘Q로 끝내면 저장 질문 없이 닫힌다.
set -euo pipefail
source "${0:A:h}/derived-data.sh"   # cd 앞에서(상대 경로로 부를 때 ${0:A}가 cd 뒤 위치로 풀리지 않게)
cd "${0:A:h}/.."
APP=${APP:-$OTF_DERIVED_DATA/Build/Products/Debug/OnTheFrame.app}
APP=${APP:A}   # 절대 경로(APP를 상대 경로로 줘도 됨)
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
[[ -f .build/test-work/fixtures/otf-TA.mp4 ]] || Engine/.build/debug/otf-dev fixtures .build/test-work/fixtures > /dev/null
F=selftest-work/manual-spectrum-lane
rm -rf $F
mkdir -p $F/sources
cp -c .build/test-work/fixtures/otf-TA.mp4 $F/sources/
open -n -a "$APP" "$PWD/$F" --args -OTFLayoutSuite dev.ontheframe.manual.spectrumlane -OTFLayoutReset -OTFSpectrumLaneManual
for i in {1..60}; do [[ -f $F/spectrum-lane-manual.json ]] && break; sleep 1; done
[[ -f $F/spectrum-lane-manual.json ]] || { echo "no setup result (timeout)"; exit 1 }
cat $F/spectrum-lane-manual.json; echo
grep -q '"setup" : "ok"' $F/spectrum-lane-manual.json || { echo "setup failed"; exit 1 }
echo "창이 열려 있습니다. 확인을 마치면 창을 닫거나 ⌘Q로 끝내세요(저장하지 마세요)."
