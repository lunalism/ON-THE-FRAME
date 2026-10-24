#!/bin/zsh
# 샌드박스 앱 자체 검사(Debug 빌드). 생성 fixture만 쓴다.
# 1) fixture 생성(app/.build/test-work/fixtures) 2) 실행 폴더 app/selftest-work/run-<시각>에 복제(cp -c)
# 3) 앱을 그 폴더로 실행(Launch Services가 폴더 접근을 허락) 4) otf-dev verify로 판정(verify-result.json)
# 폴더 밖 접근 거부 확인용으로 app/selftest-work/outside-probe.txt를 둔다. 실행 폴더는 판정 뒤 지운다(KEEP=1이면 남김).
set -euo pipefail
source "${0:A:h}/derived-data.sh"   # cd 앞에서(상대 경로로 부를 때 ${0:A}가 cd 뒤 위치로 풀리지 않게)
cd "${0:A:h}/.."
APP=${APP:-$OTF_DERIVED_DATA/Build/Products/Debug/OnTheFrame.app}
APP=${APP:A}   # 절대 경로(APP를 상대 경로로 줘도 됨)
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
DEV=Engine/.build/debug/otf-dev
$DEV fixtures .build/test-work/fixtures
mkdir -p selftest-work
echo "outside" > selftest-work/outside-probe.txt
RUN=selftest-work/run-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
for f in .build/test-work/fixtures/*(.); do cp -c $f $RUN/sources/; done
echo "launching sandboxed app on $RUN"
# -n: 새 인스턴스, -W: 끝날 때까지 기다림. 앱은 검사 뒤 스스로 종료한다(제한 시간 300초).
( open -n -W -a "$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFSelfTest ) &
OPENPID=$!
for i in {1..300}; do [[ -f $RUN/selftest-result.json ]] && break; sleep 1; done
wait $OPENPID || true
[[ -f $RUN/selftest-result.json ]] || { echo "no result (timeout)"; exit 1 }
set +e
$DEV verify $RUN
RC=$?
set -e
if [[ "${KEEP:-0}" != 1 ]]; then cp $RUN/verify-result.json selftest-work/last-verify-result.json; cp $RUN/selftest-result.json selftest-work/last-selftest-result.json; rm -rf $RUN; fi
exit $RC
