#!/bin/zsh
# 단축키 경로 자체 검사(Debug 빌드). 생성 fixture otf-A·otf-B만 가져오고 내보내기는 하지 않는다.
# 합성 이벤트 검사다: 입력기(IME)·하드웨어 입력 계층을 거치지 않는다. 실제 키보드 확인은 app/README.md §8.
# TRACE=1이면 키 경로 기록(-OTFKeyTrace)을 켠다.
set -euo pipefail
cd "${0:A:h}/.."
APP=.build/DerivedData/Build/Products/Debug/OnTheFrame.app
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
[[ -f .build/test-work/fixtures/otf-A.mp4 ]] || { swift build --package-path Engine --product otf-dev >/dev/null; Engine/.build/debug/otf-dev fixtures .build/test-work/fixtures; }
RUN=selftest-work/keys-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
cp -c .build/test-work/fixtures/otf-A.mp4 .build/test-work/fixtures/otf-B.mp4 $RUN/sources/
( open -n -W -a "$PWD/$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFShortcutTest ${TRACE:+-OTFKeyTrace} ) &
OPENPID=$!
for i in {1..120}; do [[ -f $RUN/shortcut-result.json ]] && break; sleep 1; done
wait $OPENPID || true
[[ -f $RUN/shortcut-result.json ]] || { echo "no result (timeout)"; exit 1 }
set +e
python3 -I - $RUN/shortcut-result.json <<'PY'
import json,sys
c=json.load(open(sys.argv[1])); f=[x for x in c if not x['pass']]
for x in c: print('PASS' if x['pass'] else 'FAIL', x['name'], ('— '+x['detail']) if x['detail'] else '')
print(f"{len(c)-len(f)}/{len(c)} pass"); sys.exit(1 if f else 0)
PY
RC=$?
cp $RUN/shortcut-result.json selftest-work/last-shortcut-result.json
[[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
exit $RC
