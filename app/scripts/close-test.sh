#!/bin/zsh
# 닫기·종료 보호 자체 검사(Debug 빌드). 두 번 실행한다: window(창 닫기 취소·버리기), quit-export(종료 취소, 내보내는 중 버리고 종료).
# 마지막 버리기는 앱을 끝내므로, 앱 종료와 내보내기 정리는 이 스크립트가 확인한다.
set -euo pipefail
cd "${0:A:h}/.."
APP=.build/DerivedData/Build/Products/Debug/OnTheFrame.app
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
[[ -f .build/test-work/fixtures/otf-A.mp4 ]] || { swift build --package-path Engine --product otf-dev >/dev/null; Engine/.build/debug/otf-dev fixtures .build/test-work/fixtures; }
FAILS=0
for MODE in window quit-export; do
  RUN=selftest-work/close-$MODE-$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p $RUN/sources
  cp -c .build/test-work/fixtures/otf-A.mp4 .build/test-work/fixtures/otf-B.mp4 $RUN/sources/
  T0=$(date +%s)
  open -n -W -a "$PWD/$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFCloseTest $MODE &
  OPENPID=$!
  EXITED=0
  for i in {1..240}; do if ! kill -0 $OPENPID 2>/dev/null; then EXITED=1; break; fi; sleep 1; done
  echo "== $MODE (app exited: $EXITED, $(( $(date +%s) - T0 ))s)"
  [[ $EXITED == 1 ]] || { echo "FAIL app did not exit"; FAILS=$((FAILS+1)); pkill -f "$RUN" || true; }
  python3 -I - $RUN/close-result.json $MODE <<'PY' || FAILS=$((FAILS+1))
import json,os,sys
r=json.load(open(sys.argv[1])); mode=sys.argv[2]; bad=0
for c in r['checks']:
    print('PASS' if c['pass'] else 'FAIL', c['name'], ('— '+c['detail']) if c['detail'] else '')
    bad += 0 if c['pass'] else 1
ok = r.get('pendingDiscard') == mode
print('PASS' if ok else 'FAIL', 'reachedFinalDiscard', r.get('pendingDiscard')); bad += 0 if ok else 1
if mode == 'quit-export':
    d=r.get('exportDestination'); t=r.get('exportTempDir')
    a = d is not None and not os.path.exists(d); b = t is not None and not os.path.exists(t)
    print('PASS' if a else 'FAIL', 'discard.noDestinationFile'); print('PASS' if b else 'FAIL', 'discard.tempDirRemoved', 'recorded' if t else 'not recorded')
    bad += (0 if a else 1) + (0 if b else 1)
sys.exit(1 if bad else 0)
PY
  cp $RUN/close-result.json selftest-work/last-close-$MODE.json 2>/dev/null || true
  [[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
done
echo $([[ $FAILS == 0 ]] && echo "OVERALL PASS" || echo "OVERALL FAIL ($FAILS)")
exit $FAILS
