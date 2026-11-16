# 이 프로젝트의 Xcode DerivedData 위치(2026-10-24 소유자 승인, 옵션 (가)). 다른 스크립트가 source 한다.
# 내부 APFS 볼륨의 전용 디렉터리: 저장소 데이터 볼륨(HFS+)에서는 LLVM 컴파일 캐시의 희소 파일이 전부 할당돼 약 37 GiB가 됐다
# (docs/SPECTRUM-DESIGN.md §10.11). OTF_DERIVED_DATA로 바꿀 수 있다. 전역 Xcode 설정은 바꾸지 않는다. 20 GiB 산출물 예산에 포함한다.
OTF_DERIVED_DATA=${OTF_DERIVED_DATA:-$HOME/Library/Developer/ON-THE-FRAME/DerivedData}
