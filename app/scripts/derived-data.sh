# 이 프로젝트의 빌드 산출물 위치. 다른 스크립트(zsh, set -euo pipefail)가 cd 앞에서 source 한다.
# 2026-11-21 소유자 정책(FX02C-EXTERNAL-BUILD-01, FX02C-CHECKPOINT-01): 외부 APFS 볼륨 /Volumes/Data에 둔다.
#   DerivedData  /Volumes/Data/ON-THE-FRAME-Builds/DerivedData/<작업별 이름>
#   결과·로그     /Volumes/Data/ON-THE-FRAME-Builds/Results/<작업별 이름>
#   보관          /Volumes/Data/ON-THE-FRAME-Archives/
# 이전 기본값 $HOME/Library/Developer/ON-THE-FRAME/DerivedData(2026-10-24, 당시 데이터 볼륨 HFS+)는 쓰지 않는다.
# 볼륨이 마운트되지 않았거나 APFS가 아니거나 쓸 수 없으면 실패한다(source가 1을 돌려줘 호출 스크립트가 멈춘다).
# 내부 디스크로 자동 대체하지 않고, 디렉터리를 만들지 않으며, 전역 Xcode 설정을 바꾸지 않는다.
# OTF_DERIVED_DATA로 작업별 경로를 줄 수 있으나 같은 외부 볼륨의 OTF_BUILD_ROOT 아래여야 한다.
# 관리 디스크 예산 계산은 app/README.md "현재 실행 승인과 자원 안전"을 따른다.
OTF_EXTERNAL_VOLUME=/Volumes/Data
OTF_BUILD_ROOT=$OTF_EXTERNAL_VOLUME/ON-THE-FRAME-Builds
OTF_BUILD_RESULTS=$OTF_BUILD_ROOT/Results
OTF_ARCHIVES=$OTF_EXTERNAL_VOLUME/ON-THE-FRAME-Archives
OTF_DERIVED_DATA=${OTF_DERIVED_DATA:-$OTF_BUILD_ROOT/DerivedData/scripts-default}

otf_require_external_build_location() {
  local mount_line mounted existing
  mount_line=$(/sbin/mount | /usr/bin/grep -F " on $OTF_EXTERNAL_VOLUME (apfs," || true)
  if [[ -z $mount_line ]]; then
    print -u2 "derived-data.sh: $OTF_EXTERNAL_VOLUME 가 APFS로 마운트되어 있지 않다. 내부 디스크로 대체하지 않고 멈춘다."
    return 1
  fi
  if [[ ! -d $OTF_BUILD_ROOT || -L $OTF_BUILD_ROOT || ! -w $OTF_BUILD_ROOT ]]; then
    print -u2 "derived-data.sh: $OTF_BUILD_ROOT 가 없거나 링크이거나 쓸 수 없다. 멈춘다."
    return 1
  fi
  case $OTF_DERIVED_DATA in
    $OTF_BUILD_ROOT/*) ;;
    *) print -u2 "derived-data.sh: OTF_DERIVED_DATA=$OTF_DERIVED_DATA 는 $OTF_BUILD_ROOT 아래가 아니다. 멈춘다."; return 1 ;;
  esac
  if [[ $OTF_DERIVED_DATA == *'/../'* || $OTF_DERIVED_DATA == *'/..' ]]; then
    print -u2 "derived-data.sh: OTF_DERIVED_DATA에 '..'를 쓰지 않는다. 멈춘다."
    return 1
  fi
  # 가장 가까운 기존 상위 경로가 실제로 외부 볼륨에 있는지(빈 마운트 지점·링크로 내부 디스크에 쓰지 않게) 확인한다.
  existing=$OTF_DERIVED_DATA
  while [[ ! -e $existing ]]; do existing=${existing:h}; done
  mounted=$(/bin/df -P "$existing" 2>/dev/null | /usr/bin/awk 'NR==2 {print $6}')
  if [[ $mounted != $OTF_EXTERNAL_VOLUME || ! -w $existing ]]; then
    print -u2 "derived-data.sh: $existing 이 $OTF_EXTERNAL_VOLUME 볼륨이 아니거나 쓸 수 없다(마운트 지점: ${mounted:-없음}). 멈춘다."
    return 1
  fi
}
otf_require_external_build_location || return 1
