# 관리 산출물 저장공간 예산의 단일 기준(2026-11-27 소유자 결정, OTF-STORAGE-MANAGEMENT-116A). 다른 zsh 스크립트가 source 한다.
# 값: 조기 중지 39.25 GiB, hard 중지 40 GiB. 단위 KiB(du -sk 할당 크기, 1 GiB = 1048576 KiB).
# 합산 범위와 세는 방법은 app/README.md "현재 실행 승인과 자원 안전"과 같다(이 파일은 범위를 바꾸지 않는다).
# /Volumes/Data/ON-THE-FRAME-Archives/는 예산 밖이며 따로 측정한다.
# 메모리 한도(컴파일러 RSS 1280 MiB, 작업 트리 2.7 GiB, memory pressure)는 이 파일이 다루지 않는다(그대로).
# 과거 작업 폴더(Results/*)의 실행기는 당시 값(19.25/20 GiB)을 담은 증거이며 이 파일로 바뀌지 않는다.
#
# 함수
#   otf_managed_kib         합산 범위의 할당 KiB를 출력한다. 측정 실패(du 오류, 숫자 아님)면 아무것도 출력하지 않고 1을 돌려준다.
#   otf_budget_check <KiB>  0 허용(조기 중지 미만) · 1 STOP(조기 중지 이상) · 2 HARD STOP(hard 이상) · 3 STOP(값을 알 수 없음).
#                           판정 한 줄을 출력한다. 경계값은 중지 쪽이다(정확히 39.25 GiB면 STOP, 정확히 40 GiB면 HARD STOP).
OTF_BUDGET_EARLY_KIB=41156608   # 39.25 GiB
OTF_BUDGET_HARD_KIB=41943040    # 40 GiB

otf_managed_kib() {
  emulate -L zsh
  setopt nullglob
  local repo=${OTF_REPO:-/Volumes/Data/dev/ON-THE-FRAME} du=${OTF_BUDGET_DU:-du} t=0 p out k
  local -a roots
  roots=($repo/app/.build $repo/app/Engine/.build $repo/app/selftest-work $repo/experiments/*/artifacts $repo/experiments/*/.build
         ${OTF_BUILD_ROOT:-/Volumes/Data/ON-THE-FRAME-Builds}/DerivedData ${OTF_BUILD_ROOT:-/Volumes/Data/ON-THE-FRAME-Builds}/Results
         $HOME/Library/Developer/ON-THE-FRAME)
  for p in $roots; do
    [[ -e $p ]] || continue
    out=$($du -sk "$p" 2>/dev/null) || return 1
    k=${out%%[[:space:]]*}
    [[ $k == <-> ]] || return 1
    t=$((t + k))
  done
  print -r -- $t
}

otf_budget_check() {
  emulate -L zsh
  local v=${1:-}
  if [[ $v != <-> ]]; then print -r -- "STOP: managed storage unknown ('$v')"; return 3; fi
  if (( v >= OTF_BUDGET_HARD_KIB )); then print -r -- "HARD STOP: managed storage $v KiB >= $OTF_BUDGET_HARD_KIB KiB (40 GiB)"; return 2; fi
  if (( v >= OTF_BUDGET_EARLY_KIB )); then print -r -- "STOP: managed storage $v KiB >= $OTF_BUDGET_EARLY_KIB KiB (39.25 GiB early stop)"; return 1; fi
  print -r -- "OK: managed storage $v KiB < $OTF_BUDGET_EARLY_KIB KiB (39.25 GiB early stop)"
  return 0
}
