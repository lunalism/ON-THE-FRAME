#!/bin/zsh
# 시트·알림·앱 모달 중 파일 명령 보호(CP-03)와 레인 삭제 확인의 프로젝트 확인(CP-02) 자체 검사(Debug, 2026-10-12).
# 생성 fixture(otf-TA)만. 실제 저장·열기 패널은 띄우지 않고, 프로젝트 파일은 검사 폴더 안에만 쓴다.
set -euo pipefail
cd "${0:A:h}/.."
APP=${APP:-.build/DerivedData/Build/Products/Debug/OnTheFrame.app}
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
Engine/.build/debug/otf-dev fixtures .build/test-work/fixtures > /dev/null
RUN=selftest-work/fileguard-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
cp -c .build/test-work/fixtures/otf-TA.mp4 $RUN/sources/
( open -n -W -a "$PWD/$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFFileGuardTest ) &
OPENPID=$!
for i in {1..300}; do [[ -f $RUN/fileguard-result.json ]] && break; kill -0 $OPENPID 2>/dev/null || break; sleep 1; done
wait $OPENPID || true
if [[ ! -f $RUN/fileguard-result.json ]]; then
  echo "no result (app ended without result — crashed or timed out). progress:"
  cat $RUN/fileguard-progress.txt 2>/dev/null || echo "(no progress file)"
  [[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
  exit 1
fi
cp $RUN/fileguard-result.json selftest-work/last-fileguard-result.json
python3 - $RUN/fileguard-result.json <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
for c in r: print("PASS" if c["pass"] else "FAIL", c["name"], ("— "+c["detail"][:400]) if c["detail"] else "")
f=[c for c in r if not c["pass"]]
print("OVERALL PASS" if not f else f"OVERALL FAIL ({len(f)})")
sys.exit(1 if f else 0)
PY
RC=$?
[[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
exit $RC
