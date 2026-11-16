#!/bin/zsh
# CP-04 수동 확인용 일회용 fixture(Debug, 2026-10-12). 생성 fixture만 쓰고 selftest-work/manual-cp04 안에만 만든다.
# 앱(샌드박스)이 원본 북마크를 만들도록 Debug 앱이 프로젝트를 만들고 저장한다(-OTFMakeManualRelinkFixture, 저장 패널 없음).
# 그 뒤 이 폴더의 otf-TA 사본만 지워 "찾을 수 없는 원본" 하나를 만들고, 교체용 파일을 replacement/에 둔다.
# 소유자 미디어·프로젝트는 건드리지 않는다. 다시 실행하면 이 폴더만 새로 만든다. 앱 경로를 APP으로 바꿀 수 있다.
set -euo pipefail
source "${0:A:h}/derived-data.sh"   # cd 앞에서(상대 경로로 부를 때 ${0:A}가 cd 뒤 위치로 풀리지 않게)
cd "${0:A:h}/.."
APP=${APP:-$OTF_DERIVED_DATA/Build/Products/Debug/OnTheFrame.app}
APP=${APP:A}   # 절대 경로(APP를 상대 경로로 줘도 됨)
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
[[ -f .build/test-work/fixtures/otf-TA.mp4 ]] || Engine/.build/debug/otf-dev fixtures .build/test-work/fixtures > /dev/null
F=selftest-work/manual-cp04
rm -rf $F
mkdir -p $F/sources $F/replacement
cp -c .build/test-work/fixtures/otf-TA.mp4 .build/test-work/fixtures/otf-TB.mp4 $F/sources/
open -n -W -a "$APP" "$PWD/$F" --args -OTFLayoutSuite dev.ontheframe.manual.cp04.make -OTFLayoutReset -OTFMakeManualRelinkFixture
[[ "$(cat $F/fixture-made.txt 2>/dev/null)" == ok ]] || { echo "fixture project not made"; exit 1 }
rm $F/fixture-made.txt
cp -c .build/test-work/fixtures/otf-TA.mp4 $F/replacement/otf-TA-replacement.mp4
rm $F/sources/otf-TA.mp4   # 이 fixture의 사본만 지운다
echo "project:     $PWD/$F/cp04-manual.ontheframe"
echo "replacement: $PWD/$F/replacement/otf-TA-replacement.mp4"
