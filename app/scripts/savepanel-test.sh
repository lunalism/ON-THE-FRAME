#!/bin/zsh
# 실제 저장 패널 프로젝트 저장 회귀 검사(Debug, 2026-10-10 저장 실패). 메뉴 "프로젝트 저장"으로 실제 NSSavePanel을 띄우고
# 확인 단추를 눌러 처음 저장·이후 저장·다른 이름으로 저장·다시 열기를 본다. 기본 위치는 실행 폴더(out). DESKTOP=1이면 바탕화면에
# 새 고유 이름으로 저장하고 끝나면 그 두 파일을 지운다(기존 파일은 건드리지 않음). 앱 경로를 APP으로 바꿀 수 있다.
set -euo pipefail
source "${0:A:h}/derived-data.sh"   # cd 앞에서(상대 경로로 부를 때 ${0:A}가 cd 뒤 위치로 풀리지 않게)
cd "${0:A:h}/.."
APP=${APP:-$OTF_DERIVED_DATA/Build/Products/Debug/OnTheFrame.app}
APP=${APP:A}   # 절대 경로(APP를 상대 경로로 줘도 됨)
[[ -d $APP ]] || { echo "build first"; exit 2 }
RUN=selftest-work/savepanel-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
cp -c .build/test-work/fixtures/otf-A.mp4 $RUN/sources/
EXTRA=(); [[ "${DESKTOP:-0}" == 1 ]] && EXTRA=(-OTFSavePanelDesktop)
( open -n -W -a "$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFSavePanelTest $EXTRA ) &
OPENPID=$!
wait $OPENPID || true
set +e
python3 - "$RUN/savepanel-result.json" <<'PY'
import json, sys, os
d = json.load(open(sys.argv[1]))
for c in d["checks"]: print("PASS" if c["pass"] else "FAIL", c["name"], "—", c["detail"])
bad = [c for c in d["checks"] if not c["pass"]] or ([] if len(d["checks"]) == 4 else ["incomplete"])
for p in d["created"]:
    if p.startswith(os.path.expanduser("~/Desktop/otf-diag-")) and os.path.exists(p): os.remove(p); print("removed", p)
print("OVERALL PASS" if not bad else "OVERALL FAIL")
sys.exit(1 if bad else 0)
PY
RC=$?
[[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
exit $RC
