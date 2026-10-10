#!/bin/zsh
# ON THE FRAME 앱 빌드(Debug, ad-hoc 서명, App Sandbox). 산출물: app/.build/DerivedData(Git 무시)
set -euo pipefail
cd "${0:A:h}/.."
xcodebuild -project OnTheFrame.xcodeproj -scheme OnTheFrame -configuration "${1:-Debug}" \
  -derivedDataPath .build/DerivedData COMPILER_INDEX_STORE_ENABLE=NO build | grep -E "error|warning:|BUILD" || true
echo "app: $(pwd)/.build/DerivedData/Build/Products/${1:-Debug}/OnTheFrame.app"
