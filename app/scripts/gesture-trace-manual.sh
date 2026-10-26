#!/bin/zsh
# 끌기 중 실제 ⌘Tab 소유자 확인 기록(Debug, 2026-10-26, SP-1A 2C-1 소유자 실패 조사). 앱 동작은 바꾸지 않는다.
# 1) 실시간 기록(`trace` 범주 — Debug `dbg` 줄: 누름·놓기·끌기 시작·확정·취소·중단 이유·앱 활성·창 키·왼쪽 버튼·⌘ 누름/뗌)을
#    selftest-work/gesture-trace-<시각>.log에 받는다. 경로·파일 이름은 기록에 없다(§28.6).
# 2) spectrum-project-manual.sh로 일회용 폴더·따로 둔 설정의 Debug 앱을 연다(소유자 프로젝트·원본은 쓰지 않음).
# 3) 소유자가 Return을 누르면 기록을 멈추고 끌기 관련 줄만 보인다. 앱 경로를 APP으로 바꿀 수 있다.
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p selftest-work
LOG=selftest-work/gesture-trace-$(date -u +%Y%m%dT%H%M%SZ).log
/usr/bin/log stream --info --style compact --predicate 'subsystem == "dev.ontheframe.app" AND category == "trace"' > $LOG 2>&1 &
LP=$!
trap 'kill $LP 2>/dev/null || true' EXIT
scripts/spectrum-project-manual.sh
echo
echo "기록 중: $PWD/$LOG"
echo "Debug 앱에서 (1) 스펙트럼 끌기 중 ⌘Tab, (2) 클립 끌기 중 ⌘Tab을 각각 한 번씩 하고, 마우스 버튼을 언제 놓았는지 적어 두세요."
echo "다 했으면 여기서 Return을 누르세요."
read -r _
kill $LP 2>/dev/null || true
trap - EXIT
echo "끌기 관련 줄:"
grep -E "dbg (timeline (mouseDown|mouseUp|moveStartsFromPress|viewDragCleared)|begin|commit|cancel|interrupt|lifecycle|key command)" $LOG || echo "(줄 없음)"
echo "전체 기록: $PWD/$LOG"
