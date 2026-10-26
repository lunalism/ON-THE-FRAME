#!/bin/zsh
# 스펙트럼 프로젝트 열기 소유자 확인(Debug, 2026-10-26, SP-1A 2B-1). 생성 fixture(otf-TA — 저장 파일용, otf-TB·aud-wav48s — 가져오기용)만 쓰고 selftest-work/manual-spectrum-project 안에만 만든다.
# 1) Debug 앱이 저장 파일 두 개를 보통 저장 경로로 만든다(-OTFMakeSpectrumProjects, 저장 패널 없음):
#    rich.ontheframe(스펙트럼 레인 3개·항목 4개 — 소스 정상·바꾼 모양·소스 없음·고르지 않음, 빈 레인, 계보, 자막 효과)
#    missing-media.ontheframe(소스는 정상, 이 폴더의 미디어 사본을 지워 원본 파일 없음)
# 가져오기용 fixture(otf-TB.mp4·aud-wav48s.wav)를 import/에 둔다(2B 통합 확인).
# 2) 따로 둔 설정 저장소(-OTFLayoutSuite)로 Debug 앱을 보통 상태로 연다. 소유자가 파일 > 열기로 이 폴더의 파일을 연다.
# 소유자의 프로젝트·원본은 쓰지 않는다. 다시 실행하면 이 폴더만 새로 만든다. 앱 경로를 APP으로 바꿀 수 있다.
set -euo pipefail
source "${0:A:h}/derived-data.sh"   # cd 앞에서(상대 경로로 부를 때 ${0:A}가 cd 뒤 위치로 풀리지 않게)
cd "${0:A:h}/.."
APP=${APP:-$OTF_DERIVED_DATA/Build/Products/Debug/OnTheFrame.app}
APP=${APP:A}   # 절대 경로(APP를 상대 경로로 줘도 됨)
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
[[ -f .build/test-work/fixtures/otf-TA.mp4 ]] || Engine/.build/debug/otf-dev fixtures .build/test-work/fixtures > /dev/null
F=selftest-work/manual-spectrum-project
SUITE=dev.ontheframe.manual.spectrumproject
rm -rf $F
mkdir -p $F/sources
cp -c .build/test-work/fixtures/otf-TA.mp4 $F/sources/
cp -c .build/test-work/fixtures/otf-TA.mp4 $F/sources/otf-TA-copy.mp4
open -n -W -a "$APP" "$PWD/$F" --args -OTFLayoutSuite $SUITE -OTFLayoutReset -OTFMakeSpectrumProjects
[[ "$(cat $F/spectrum-projects-made.txt 2>/dev/null)" == ok ]] || { echo "fixture projects not made"; exit 1 }
rm $F/spectrum-projects-made.txt
rm $F/sources/otf-TA-copy.mp4   # 이 fixture의 사본만 지운다(missing-media.ontheframe의 원본 파일 없음)
mkdir -p $F/import   # 2B 통합 확인(2026-10-26): 가져오기용 영상·소리 fixture(실제 영상 대신 쓸 수 있음)
cp -c .build/test-work/fixtures/otf-TB.mp4 .build/test-work/fixtures/aud-wav48s.wav $F/import/
echo "rich:          $PWD/$F/rich.ontheframe"
echo "missing media: $PWD/$F/missing-media.ontheframe"
echo "import:        $PWD/$F/import (otf-TB.mp4 영상, aud-wav48s.wav 소리)"
[[ "${NO_LAUNCH:-0}" == 1 ]] && exit 0
open -n -a "$APP" --args -OTFLayoutSuite $SUITE
echo "Debug 앱을 열었습니다. 파일 > 열기(⌘O)로 위 파일을 여세요. 소중한 프로젝트로 시험하지 마세요."
