#!/bin/zsh
# 변형 끌기 측정(Debug 빌드). 생성 fixture otf-TA·otf-TB만. 프리뷰 테두리의 손잡이 크기 조절·옮기기를 합성 포인터 100번으로 끌고
# 포인터 처리 시간·화면 갱신 간격·지연·주 실행 루프 바쁜 시간을 perf-result.json으로 남긴다(합성 이벤트 측정, 실제 손 끌기를 대신하지 않음).
set -euo pipefail
cd "${0:A:h}/.."
APP=${APP:-.build/DerivedData/Build/Products/Debug/OnTheFrame.app}
[[ -d $APP ]] || { echo "build first: scripts/build.sh"; exit 2 }
swift build --package-path Engine --product otf-dev 2>&1 | grep -E "error|warning:" || true
Engine/.build/debug/otf-dev fixtures .build/test-work/fixtures > /dev/null
RUN=selftest-work/perf-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p $RUN/sources
for f in otf-TA.mp4 otf-TB.mp4; do cp -c .build/test-work/fixtures/$f $RUN/sources/; done
( open -n -W -a "$PWD/$APP" "$PWD/$RUN" --args -OTFLayoutSuite dev.ontheframe.test.layout -OTFLayoutReset -OTFTransformPerfTest ) &
OPENPID=$!
for i in {1..180}; do [[ -f $RUN/perf-result.json ]] && break; sleep 1; done
wait $OPENPID || true
[[ -f $RUN/perf-result.json ]] || { echo "no result (timeout)"; exit 1 }
cp $RUN/perf-result.json selftest-work/last-perf-result-${LABEL:-run}.json
python3 - $RUN/perf-result.json <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
print("mode", r["mode"])
for s in r["stats"]:
    print(f'{s["scenario"]}: events {s["events"]} handler mean {s["handlerMeanMs"]:.2f} max {s["handlerMaxMs"]:.2f} ms | main busy {s["busyFraction"]*100:.0f}% max {s["busyMaxMs"]:.1f} ms >16.7ms {s["busyOver16"]} | '
          f'shown {s["shownUpdates"]} interval mean {s["shownIntervalMeanMs"]:.1f} max {s["shownIntervalMaxMs"]:.1f} ms | latency mean {s["latencyMeanMs"]:.1f} max {s["latencyMaxMs"]:.1f} ms (unmatched {s["unmatchedShown"]}) | '
          f'render mean {s["renderMeanMs"]:.2f} max {s["renderMaxMs"]:.2f} ms n {s["renders"]} | max width jump {s["maxWidthJumpPt"]:.1f} pt')
fails=[c for c in r["checks"] if not c["pass"]]
for c in r["checks"]: print("PASS" if c["pass"] else "FAIL", c["name"], c["detail"][:160])
sys.exit(1 if fails else 0)
PY
RC=$?
[[ "${KEEP:-0}" == 1 ]] || rm -rf $RUN
exit $RC
