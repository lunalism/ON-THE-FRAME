#!/bin/zsh
# ON THE FRAME 앱 빌드(Debug, ad-hoc 서명, App Sandbox). 산출물: $OTF_DERIVED_DATA(scripts/derived-data.sh, 외부 APFS /Volumes/Data, 볼륨이 없으면 실패)
set -euo pipefail
source "${0:A:h}/derived-data.sh"   # cd 앞에서(상대 경로로 부를 때 ${0:A}가 cd 뒤 위치로 풀리지 않게)
cd "${0:A:h}/.."
xcodebuild -project OnTheFrame.xcodeproj -scheme OnTheFrame -configuration "${1:-Debug}" \
  -derivedDataPath "$OTF_DERIVED_DATA" COMPILER_INDEX_STORE_ENABLE=NO build | grep -E "error|warning:|BUILD" || true
echo "app: $OTF_DERIVED_DATA/Build/Products/${1:-Debug}/OnTheFrame.app"
