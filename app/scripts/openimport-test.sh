#!/bin/zsh
# 프로젝트 열기(형식 1–5, 손상, 긴 원본, 취소)·가져오기(두 MP4, 취소) 회귀 자체 검사(Debug 빌드, 2026-10-11). 실제 메뉴 항목 경로.
# 생성 fixture와 진단 파일만: otf-TA·otf-TB·aud-steady48s, 3분 1080p MP4(long-180s), 형식 1(커밋 44943ea 저장기)·2–5 프로젝트.
# 끝나면 이 실행의 진단 기록(가져오기·열기 단계와 걸린 시간, 경로 없음)을 보인다.
set -euo pipefail
cd "${0:A:h}/.."
APP=${APP:-.build/DerivedData/Build/Products/Debug/OnTheFrame.app}
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
DIAG=.build/test-work/diag OLD=.build/test-work/oldproj
for f in $DIAG/long-180s.mp4 $OLD/p-v1.ontheframe $OLD/p-v5.ontheframe; do [[ -f $f ]] || { echo "missing $f (app/README.md §21 재현 명령으로 만든다)"; exit 2 }; done
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
Engine/.build/debug/otf-dev fixtures .build/test-work/fixtures > /dev/null
RUN=selftest-work/openimport-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
for f in otf-TA.mp4 otf-TB.mp4 aud-steady48s.wav; do cp -c .build/test-work/fixtures/$f $RUN/sources/; done
cp -c $DIAG/long-180s.mp4 $RUN/sources/
cp -c $OLD/p-*.ontheframe $RUN/
START=$(date "+%Y-%m-%d %H:%M:%S")
( open -n -W -a "$PWD/$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFOpenImportTest ) &
OPENPID=$!
for i in {1..240}; do [[ -f $RUN/openimport-result.json ]] && break; sleep 1; done
wait $OPENPID || true
[[ -f $RUN/openimport-result.json ]] || { echo "no result (timeout)"; exit 1 }
cp $RUN/openimport-result.json selftest-work/last-openimport-result.json
echo "--- trace (dev.ontheframe.app:trace)"
/usr/bin/log show --info --start "$START" --style compact --predicate 'subsystem == "dev.ontheframe.app" AND category == "trace"' 2>/dev/null | sed -E 's/^[0-9-]+ ([0-9:.]+) .*\[dev.ontheframe.app:trace\] /\1 /' | grep -v "^Timestamp" | tail -60 || true
python3 - $RUN/openimport-result.json <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
for c in r: print("PASS" if c["pass"] else "FAIL", c["name"], ("— "+c["detail"][:300]) if c["detail"] else "")
f=[c for c in r if not c["pass"]]
print("OVERALL PASS" if not f else f"OVERALL FAIL ({len(f)})")
sys.exit(1 if f else 0)
PY
RC=$?
[[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
exit $RC
