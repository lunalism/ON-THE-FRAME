#!/bin/zsh
# Generated images and isolated settings only. Preserve every run, including failures.
set -euo pipefail
source "${0:A:h}/derived-data.sh"
cd "${0:A:h}/.."
APP=${APP:-$OTF_DERIVED_DATA/Build/Products/Debug/OnTheFrame.app}
RUN=$(mktemp -d "$PWD/selftest-work/image-eligibility-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
echo "Evidence: $RUN"
for mode in on off; do
  mkdir "$RUN/$mode"
  flags=()
  [[ $mode == on ]] && flags=(-OTFEnableImageImport)
  open -n -a "$APP" "$RUN/$mode" --args -OTFLayoutSuite "dev.ontheframe.test.eligibility.$(uuidgen)" -ApplePersistenceIgnoreState YES -OTFImageEligibilityTest "${flags[@]}"
  found=false
  for i in {1..60}; do
    if [[ -f "$RUN/$mode/eligibility-result.json" ]]; then
      found=true
      break
    fi
    sleep 1
  done
  [[ $found == true ]] || { echo "FAIL: $mode timed out; app and evidence retained"; exit 1; }
  python3 - "$RUN/$mode/eligibility-result.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
for name, value in result['checks'].items():
    print('PASS' if value else 'FAIL', name)
print(len(result['checks']), 'checks;', result['error'])
sys.exit(0 if result['pass'] and all(result['checks'].values()) else 1)
PY
done
