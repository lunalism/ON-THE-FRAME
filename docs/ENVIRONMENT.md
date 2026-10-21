# 개발 환경 — ON THE FRAME

> Claude Code가 개발용 Mac에서 직접 조회한 값이다. 지금 관찰(2026-10-21)과 이전 관찰(2026-10-09, 기록)을 나눠 적는다. 이 문서는 관찰 기록이며, 제품의 지원 사양(최소 macOS 버전, 지원 아키텍처)을 결정하지 않는다([DECISIONS.md](DECISIONS.md) O-01).
> 개인 정보(사용자 이름, 기기 식별자, 개인 경로)는 기록하지 않는다.

## 지금 관찰(2026-10-21, 소유자의 Mac 초기화 뒤)

| 항목 | 값 | 확인 방법 |
| --- | --- | --- |
| macOS | 26.6.2 (Build 25G83) | `sw_vers` |
| CPU 아키텍처 | arm64 | `uname -m` |
| CPU | Apple M4 Pro, 논리 코어 12개 | `sysctl machdep.cpu.brand_string`, `sysctl hw.ncpu` |
| 메모리 | 24 GiB (25769803776 bytes) | `sysctl hw.memsize` |
| Xcode | 27.1 (Build 27A9275), `/Applications/Xcode.app` | `xcodebuild -version` |
| Xcode 첫 실행·라이선스 | 끝남 | `xcodebuild -checkFirstLaunchStatus`, `xcodebuild -license check`(둘 다 exit 0) |
| 활성 developer directory | Xcode.app(`/Applications/Xcode.app/Contents/Developer`) | `xcode-select -p` |
| Swift (Xcode) | 6.4 (target arm64-apple-macosx26.0) | `swift --version` |
| Apple clang (Xcode) | 21.0.0 | `clang --version` |
| 기본 SDK | macOS 27.0 | `xcrun --show-sdk-version` |
| SDK 유효 deployment target | macOS 12.0 ~ 27.0 | SDK의 `SDKSettings.json` |
| SDK 지원 아키텍처 | x86_64, x86_64h, arm64, arm64e 등 | SDK의 `SDKSettings.json` (`Archs`) — 빌드 가능 범위이며 실행 검증은 아님 |
| XCTest | Xcode 안에 있음(`Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework`) | 파일 존재 확인 |
| Command Line Tools (독립 설치) | 패키지 27.0.0.0.1788430756, Swift 6.4, SDK 26·26.5·27.0. XCTest 없음 | `pkgutil --pkg-info=com.apple.pkg.CLTools_Executables`, 디렉터리 조회 |
| 저장소 볼륨 파일 시스템 | Journaled HFS+ | `diskutil info` |
| 저장소 볼륨 용량 / 여유 공간 | 약 931GiB / 약 650GiB | `df -h` |
| 시스템 볼륨(`/`) 용량 / 여유 공간 | 약 460GiB / 약 368GiB | `df -h /` |
| 스크립트 도구 | `/usr/bin/python3` 3.9.6(앱 스크립트는 표준 라이브러리만 씀), zsh, `git` 2.54.0 | `--version` |
| 기본 측정 도구 | `/usr/bin/time`, `footprint`, `vmmap`, `hdiutil`, `shasum`, `afconvert`, `sips`, `xctrace`(Xcode) 존재 | 실행 파일 존재 여부만 확인 |
| 서드파티 | `ffmpeg`·`ffprobe`·`mediainfo` 없음(저장소가 쓰지 않음, FFmpeg 설치는 금지). Homebrew 있음(저장소가 쓰지 않음) | `which` |

**초기화 뒤 관찰한 설정 변화(2026-10-21):**

- 초기화 직후 활성 developer directory가 CommandLineTools였다(링크 시각 2026-10-20 23:17).
  - 그 동안 `swift test`는 XCTest를 찾지 못했다. `xcodebuild`(`app/scripts/build.sh`)도 실행되지 않았다.
  - 명령마다 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`를 주면 엔진 테스트가 통과했다.
- 같은 날 다시 조회했을 때 Xcode.app으로 선택되어 있었다(링크 시각 2026-10-21 16:08). Claude Code는 바꾸지 않았다(관리자 권한 필요).
- CPU·메모리·저장소 볼륨(크기·파일 시스템)이 2026-10-09 기록과 다르다. 같은 기기 여부는 확인하지 않았다.
  - 이전 성능·메모리 측정값(E1~E3, app/README)은 이전 기기의 기록이다. 지금 기기와 바로 비교하지 않는다.

## 이전 관찰(2026-10-09, 기록 — 지금 값이 아님)

| 항목 | 값 | 확인 방법 |
| --- | --- | --- |
| macOS | 26.6.2 (Build 25G83) | `sw_vers` |
| CPU 아키텍처 | arm64 | `uname -m` |
| CPU | Apple M2, 논리 코어 8개 | `sysctl machdep.cpu.brand_string`, `sysctl hw.ncpu` |
| 메모리 | 16 GB (17179869184 bytes) | `sysctl hw.memsize` |
| Xcode | 27.0 (Build 27A266a) | `xcodebuild -version` |
| 활성 developer directory | Xcode.app | `xcode-select -p` |
| Swift (Xcode) | 6.4 (target arm64-apple-macosx26.0) | `swift --version` |
| Apple clang (Xcode) | 21.0.0 | `clang --version` |
| 기본 SDK | macOS 27.0 | `xcrun --show-sdk-version` |
| SDK 유효 deployment target | macOS 12.0 ~ 27.0 | SDK의 `SDKSettings.json` (`MinimumDeploymentTarget`, `ValidDeploymentTargets`) |
| SDK 지원 아키텍처 | x86_64, x86_64h, arm64, arm64e 등 | SDK의 `SDKSettings.json` (`Archs`) — 빌드 가능 범위이며 실행 검증은 아님 |
| Command Line Tools (독립 설치) | 설치 디렉터리 존재. 포함된 Swift 6.2.4, SDK 15.4/26.2 포함 | `/Library/Developer/CommandLineTools` 조회 |
| 저장소 볼륨 파일 시스템 | APFS | `diskutil info` |
| 저장소 볼륨 용량 / 여유 공간 | 약 466GiB / 약 271GiB (2026-10-09) | `df -h` |
| 시스템 볼륨(`/`) 용량 / 여유 공간 | 약 228GiB / 약 25GiB (2026-10-09) | `df -h /` |
| 기본 측정 도구 | `/usr/bin/time`, `footprint`, `vmmap`, `hdiutil`, `shasum`, `afconvert`, `sips`, `xctrace`(Xcode) 존재 | 실행 파일 존재 여부만 확인 |

## 확인하지 못했거나 불확실한 정보

- **Command Line Tools 패키지 버전(2026-10-09)**: 그때는 `pkgutil --pkg-info=com.apple.pkg.CLTools_Executables`에 설치 receipt가 없어 공식 버전 번호를 확인하지 못했다. 그 표의 Swift/SDK 버전은 디렉터리 내용으로 추정한 것이다(2026-10-21에는 receipt가 있다).
- **Xcode 추가 구성 요소**: 설치된 시뮬레이터, 추가 플랫폼은 확인하지 않았다(라이선스·첫 실행 상태는 2026-10-21에 확인).
- **서드파티 도구**: Homebrew 설치 여부는 확인하지 않았다. 2026-10-09 E1-a 중 `which`로 `ffmpeg`, `ffprobe`, `mediainfo`가 PATH에 없음을 확인했다(설치하지 않음). E1-a 검증은 AVFoundation 디코딩과 자체 파서만 썼다.
- **GPU 세부 사양, Metal 기능 세트**: 확인하지 않았다.
- **저장소 볼륨 대소문자 구분 여부**: 확인하지 않았다(2026-10-21 파일 시스템은 Journaled HFS+).

## 참고

- 관찰한 Mac에서의 값이므로 다른 개발 기기나 사용자 기기의 환경을 대표하지 않는다.
- 도구 설치나 시스템 설정 변경은 하지 않았다(2026-10-21 포함).
