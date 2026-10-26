#!/bin/zsh
# 끌기 중 실제 앱 전환 검사(Debug, 2026-10-11, CP-01·D-031). 활성화를 Finder에 넘겨 이 앱을 실제로 비활성으로 만든다(Finder가 잠깐 앞에 온다).
# 트림·옮기기(클립·스펙트럼·자막)·프리뷰 위치·프리뷰 크기 끌기는 합성 마우스 이벤트다(실제 손 마우스·⌘Tab 아님). 놓기가 전환보다 먼저 온 경우(확정)도 관찰한다(2026-10-26). 생성 fixture(otf-TA)만, 저장하지 않는다.
set -euo pipefail
source "${0:A:h}/derived-data.sh"   # cd 앞에서(상대 경로로 부를 때 ${0:A}가 cd 뒤 위치로 풀리지 않게)
cd "${0:A:h}/.."
APP=${APP:-$OTF_DERIVED_DATA/Build/Products/Debug/OnTheFrame.app}
APP=${APP:A}   # 절대 경로(APP를 상대 경로로 줘도 됨)
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
Engine/.build/debug/otf-dev fixtures .build/test-work/fixtures > /dev/null
RUN=selftest-work/gestureswitch-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
cp -c .build/test-work/fixtures/otf-TA.mp4 $RUN/sources/
# 종류마다 새로 실행한다(앞 시도 뒤 이 앱이 활성화를 되찾지 못하면 다음 끌기가 비활성 상태에서 시작되어 검사가 무의미해짐)
for K in timeline.trim timeline.move timeline.pendingMove timeline.moveUpBeforeSwitch timeline.spectrumMove timeline.spectrumRapidSwitch timeline.spectrumUpBeforeSwitch timeline.spectrumPendingMove timeline.subtitleMove preview.position preview.resize; do
  rm -f $RUN/switch-result.json
  open -n -W -a "$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFGestureSwitchExperiment -OTFSwitchKind $K || true
  [[ -f $RUN/switch-result.json ]] || { echo "no result for $K"; exit 1 }
  mv $RUN/switch-result.json $RUN/switch-$K.json
done
python3 -c "import json,glob,sys; json.dump(sum([json.load(open(f)) for f in sorted(glob.glob(sys.argv[1]+'/switch-*.json'))],[]),open(sys.argv[1]+'/all.json','w'))" $RUN
cp $RUN/all.json selftest-work/last-gestureswitch-result.json
python3 - $RUN/all.json <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
for c in r:
    print("PASS" if c.get("pass",True) else "FAIL", c["kind"])
    for n in c["notes"]: print("    ", n)
f=[c for c in r if not c.get("pass",True)]
print("OVERALL PASS" if not f else f"OVERALL FAIL ({len(f)})")
sys.exit(1 if f else 0)
PY
RC=$?
[[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
exit $RC
