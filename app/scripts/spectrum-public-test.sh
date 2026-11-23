#!/bin/zsh
# 공개 스펙트럼 만들기·편집 자체 검사(보통 Debug 앱, SP-PUBLIC-01 2026-11-23): 문맥 메뉴·패널 명령으로 만들기, 소스 고르기, 모양, 시작·길이, 고르기·삭제,
# 실행 취소, 저장·다시 열기, 소스 없음. 생성 fixture(otf-TA)만. 실행 폴더 안에만 쓴다. 앱 경로를 APP으로 바꿀 수 있다. 빌드는 하지 않는다(별도 승인·감독).
set -euo pipefail
source "${0:A:h}/derived-data.sh"   # cd 앞에서(상대 경로로 부를 때 ${0:A}가 cd 뒤 위치로 풀리지 않게)
cd "${0:A:h}/.."
APP=${APP:-$OTF_DERIVED_DATA/Build/Products/Debug/OnTheFrame.app}
APP=${APP:A}   # 절대 경로(APP를 상대 경로로 줘도 됨)
[[ -d $APP ]] || { echo "no app at $APP (build needs separate owner approval)"; exit 2 }
# 컴파일하지 않는다(SP-PUBLIC-COMPILE-HARDEN-06): 이미 만들어 둔 생성 fixture만 쓴다. 없으면 멈춘다.
[[ -f .build/test-work/fixtures/otf-TA.mp4 ]] || { echo "NOT RUN: fixture missing (.build/test-work/fixtures/otf-TA.mp4)"; exit 3 }
RUN=selftest-work/spectrum-public-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
cp -c .build/test-work/fixtures/otf-TA.mp4 $RUN/sources/
( open -n -W -a "$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFNewProjectLanes2 -OTFSpectrumPublicTest ) &
OPENPID=$!
for i in {1..300}; do [[ -f $RUN/spectrum-public-result.json ]] && break; sleep 1; done
wait $OPENPID || true
[[ -f $RUN/spectrum-public-result.json ]] || { echo "no result (timeout)"; exit 1 }
cp $RUN/spectrum-public-result.json selftest-work/last-spectrum-public-result.json
python3 - $RUN/spectrum-public-result.json <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
for c in r: print("PASS" if c["pass"] else "FAIL", c["name"], ("— "+c["detail"][:300]) if c["detail"] else "")
f=[c for c in r if not c["pass"]]
EXPECTED=29  # 검사 28개 + 실행 방식 줄 1개(SpectrumPublicSelfTest.expectedChecks). 줄 수가 다르면 통과로 세지 않는다.
if len(r)!=EXPECTED: print(f"INCOMPLETE: {len(r)} rows (expected {EXPECTED}), {len(f)} failed"); sys.exit(4)
print("OVERALL PASS" if not f else f"OVERALL FAIL ({len(f)})")
sys.exit(1 if f else 0)
PY
RC=$?
[[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
exit $RC
