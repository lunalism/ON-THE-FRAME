#!/bin/zsh
# 스펙트럼 프리뷰 타이밍 실험(SP-0, Debug 빌드, 2026-10-24, docs/SPECTRUM-DESIGN.md §10). 생성 fixture otf-TA만.
# 멈춤: AVPlayerLayer 표시 버퍼(실제 표시)의 화면 코드 = 스펙트럼이 고른 프레임, 재생: 비디오 출력 버퍼(대리). 화면 캡처가 아니다.
# 입력 이벤트·초점을 쓰지 않으므로 앱을 뒤에서 연다(open -g). 창은 앞으로 올리되 활성화하지 않는다.
# MANUAL=1: 소유자 눈 확인용으로 같은 타임라인을 띄우고 그대로 둔다(창을 닫으면 끝). 멈춘 화면마다 기하를 실행 폴더 marker-geometry-manual-<시각>.json에 쓴다.
# RECONCILE=1: 멈춤 맞춤 비교(기준 vs 멈춘 재생 헤드로 정밀 탐색, Debug 실험) → selftest-work/pause-reconcile-<원본>-<시각>.json
#   SOURCE=<fixture 파일>: otf-TA.mp4(기본)·otf-N2997.mp4·otf-P25.mp4·otf-F23976.mp4·otf-H5994.mov(생성 fixture, RECONCILE·MANUAL에서)
# REAL=<경로>: 소유자가 허락한 실제 미디어를 open 문서로 함께 넘긴다(복사·수정 없음, 앱은 읽기만). MANUAL=1(RECONCILE=1)과 REALCHECK=1에서.
# REALCHECK=1: 멈춤 비교 20회 × 기준·맞춤(내용 대조 판별 — 실제 미디어는 화면 코드 없음) → selftest-work/real-check-…-<LABEL>.json. REAL 없으면 SOURCE fixture로 판별 검증.
# MANUAL=1 RECONCILE=1: 소유자 비교 — 떠 있는 "멈춤 맞춤 실험" 창에서 켜고 끈다(처음엔 꺼짐). 멈춤마다 실행 폴더 pause-events-manual-<시각>.json
# PAUSE=1: 멈춘 뒤 고정 어긋남 조사(40회) → selftest-work/pause-probe-<시각>.json
# GEOMETRY=1: 표시 기하 자동 기록(-OTFSpectrumMarkerGeometry) → selftest-work/marker-geometry-auto-<시각>.json
# 결과는 덮어쓰지 않는다: 타이밍 결과 selftest-work/spectrum-preview-result-<시각>.json.
set -euo pipefail
source "${0:A:h}/derived-data.sh"   # cd 앞에서(상대 경로로 부를 때 ${0:A}가 cd 뒤 위치로 풀리지 않게)
cd "${0:A:h}/.."
APP=${APP:-$OTF_DERIVED_DATA/Build/Products/Debug/OnTheFrame.app}
APP=${APP:A}   # 절대 경로(APP를 상대 경로로 줘도 됨)
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
Engine/.build/debug/otf-dev fixtures .build/test-work/fixtures > /dev/null
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
RUN=selftest-work/spectrum-preview-$STAMP
[[ ! -e $RUN ]] || { echo "run folder exists: $RUN"; exit 1 }
mkdir -p $RUN/sources
SOURCE=${SOURCE:-otf-TA.mp4}
[[ -f .build/test-work/fixtures/$SOURCE ]] || { echo "no fixture $SOURCE"; exit 2 }
cp -c .build/test-work/fixtures/otf-TA.mp4 $RUN/sources/
[[ $SOURCE == otf-TA.mp4 ]] || cp -c .build/test-work/fixtures/$SOURCE $RUN/sources/
if [[ "${MANUAL:-0}" == 1 ]]; then
  EXTRA=(-OTFReconcileSource $SOURCE)
  [[ "${RECONCILE:-0}" == 1 ]] && EXTRA+=(-OTFPauseReconcileManual)
  if [[ "${CHECK:-0}" == 1 && "${RECONCILE:-0}" == 1 ]]; then   # 수동 비교 실행 확인(자동, 단추 동작 12번) → selftest-work/pause-events-check-<시각>.json
    ( open -g -n -W -a "$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFSpectrumPreviewManual $EXTRA -OTFPauseReconcileManualCheck ) &
    wait $! || true
    G=$(ls $RUN/pause-events-manual-*.json 2>/dev/null | head -1)
    [[ -n $G ]] || { echo "no events"; exit 1 }
    cp $G selftest-work/pause-events-check-$STAMP.json; echo "manual check: selftest-work/pause-events-check-$STAMP.json"
    [[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
    exit 0
  fi
  DOCS=("$PWD/$RUN"); [[ -n ${REAL:-} ]] && { [[ -f $REAL ]] || { echo "no file: $REAL"; exit 2 }; DOCS+=("$REAL") }
  open -n -a "$APP" $DOCS --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFSpectrumPreviewManual $EXTRA
  echo "manual run folder: $RUN (기하 기록이 들어 있으니 지우지 않는다)"; exit 0
fi
if [[ "${RECONCILE:-0}" == 1 ]]; then   # 멈춤 맞춤 비교(-OTFSpectrumPauseReconcile) → selftest-work/pause-reconcile-<시각>.json
  ( open -g -n -W -a "$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFSpectrumPauseReconcile -OTFReconcileSource $SOURCE ) &
  wait $! || true
  G=$(ls $RUN/pause-reconcile-*.json 2>/dev/null | head -1)
  [[ -n $G ]] || { echo "no reconcile result"; exit 1 }
  cp $G selftest-work/${G:t}; echo "pause reconcile: selftest-work/${G:t}"
  [[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
  exit 0
fi
if [[ "${REALCHECK:-0}" == 1 ]]; then
  DOCS=("$PWD/$RUN"); [[ -n ${REAL:-} ]] && { [[ -f $REAL ]] || { echo "no file: $REAL"; exit 2 }; DOCS+=("$REAL") }
  ( open -g -n -W -a "$APP" $DOCS --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFRealMediaCheck -OTFReconcileSource $SOURCE ) &
  wait $! || true
  G=$(ls $RUN/real-check-*.json 2>/dev/null | head -1)
  [[ -n $G ]] || { echo "no real-check result"; exit 1 }
  cp $G selftest-work/${G:t:r}-${LABEL:-run}.json; echo "real check: selftest-work/${G:t:r}-${LABEL:-run}.json"
  [[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
  exit 0
fi
if [[ "${PHASE:-0}" == 1 ]]; then   # 멈춤 위상 쓸기(-OTFSpectrumPausePhase, 원본당 84회, 측정만) → selftest-work/pause-phase-<원본>-<시각>.json
  ( open -g -n -W -a "$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFSpectrumPausePhase -OTFReconcileSource $SOURCE ) &
  wait $! || true
  G=$(ls $RUN/pause-phase-*.json 2>/dev/null | head -1)
  [[ -n $G ]] || { echo "no pause-phase result"; exit 1 }
  cp $G selftest-work/${G:t}; echo "pause phase: selftest-work/${G:t}"
  [[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
  exit 0
fi
if [[ "${PAUSE:-0}" == 1 ]]; then   # 멈춘 뒤 고정 어긋남 조사(-OTFSpectrumPauseProbe, 40회) → selftest-work/pause-probe-<시각>.json
  ( open -g -n -W -a "$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFSpectrumPauseProbe ) &
  wait $! || true
  G=$(ls $RUN/pause-probe-*.json 2>/dev/null | head -1)
  [[ -n $G ]] || { echo "no pause-probe result"; exit 1 }
  cp $G selftest-work/${G:t}; echo "pause probe: selftest-work/${G:t}"
  [[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
  exit 0
fi
if [[ "${GEOMETRY:-0}" == 1 ]]; then
  ( open -g -n -W -a "$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFSpectrumMarkerGeometry ) &
  OPENPID=$!
  wait $OPENPID || true
  G=$(ls $RUN/marker-geometry-auto-*.json 2>/dev/null | head -1)
  [[ -n $G ]] || { echo "no geometry result"; exit 1 }
  cp $G selftest-work/${G:t}
  python3 - selftest-work/${G:t} <<'PY'
import json,sys
for g in json.load(open(sys.argv[1])):
    gp=g.get("gapsPx") or {}
    print(f'k {g["k"]:3} src {g["expectedSrc"]:3} layer {g["layerSrc"]} box {g["boxInBuffer"] and [round(x,2) for x in g["boxInBuffer"]]} offset {g["boxOffsetVsExpected"] and round(g["boxOffsetVsExpected"],2)} gaps(px) ' +
          " ".join(f'{k} {gp[k]:.2f}' for k in ("left","right","top","bottom") if k in gp) + f' design {g["designGapPx"]:.2f} scale {g["backingScale"]} videoRect {[round(x,2) for x in g["videoRect"]]}')
PY
  echo "geometry: selftest-work/${G:t}"
  [[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
  exit 0
fi
( open -g -n -W -a "$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFSpectrumPreviewTest ) &
OPENPID=$!
for i in {1..300}; do [[ -f $RUN/spectrum-preview-result.json ]] && break; sleep 1; done
wait $OPENPID || true
[[ -f $RUN/spectrum-preview-result.json ]] || { echo "no result (timeout)"; exit 1 }
cp $RUN/spectrum-preview-result.json selftest-work/spectrum-preview-result-$STAMP.json
echo "result: selftest-work/spectrum-preview-result-$STAMP.json"
set +e
python3 - $RUN/spectrum-preview-result.json <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
for p in r["phases"]: print(f'{p["phase"]:20} samples {p["samples"]:4} compared {p["compared"]:4} mismatch {p["mismatches"]:3} blank {p["blank"]:3} unreadable {p["unreadable"]:3} {p["kind"]}', *p["firstMismatches"][:4], sep="\n    " if p["firstMismatches"] else " ")
for x in r["resources"]: print("RES", x)
for n in r["notes"]: print("NOTE", n)
for c in r["checks"]: print("PASS" if c["pass"] else "FAIL", c["name"], ("— "+c["detail"]) if c["detail"] else "")
f=[c for c in r["checks"] if not c["pass"]]
print("OVERALL PASS" if not f else f"OVERALL FAIL ({len(f)})")
sys.exit(1 if f else 0)
PY
RC=$?
[[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
exit $RC
