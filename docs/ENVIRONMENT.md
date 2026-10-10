# 개발 환경 — ON THE FRAME

> 2026-10-09에 Claude Code가 개발용 Mac에서 직접 조회한 값이다. 이 문서는 관찰 기록이며, 제품의 지원 사양(최소 macOS 버전, 지원 아키텍처)을 결정하지 않는다([DECISIONS.md](DECISIONS.md) O-01).
> 개인 정보(사용자 이름, 기기 식별자, 개인 경로)는 기록하지 않는다.

## 관찰된 환경

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

- **Command Line Tools 패키지 버전**: `pkgutil --pkg-info=com.apple.pkg.CLTools_Executables`에 설치 receipt가 없어 공식 버전 번호를 확인하지 못했다. 위 Swift/SDK 버전은 디렉터리 내용으로 추정한 것이다.
- **Xcode 추가 구성 요소**: 설치된 시뮬레이터, 추가 플랫폼, Xcode 라이선스 동의 상태는 확인하지 않았다.
- **서드파티 도구**: Homebrew 설치 여부는 확인하지 않았다. 2026-10-09 E1-a 중 `which`로 `ffmpeg`, `ffprobe`, `mediainfo`가 PATH에 없음을 확인했다(설치하지 않음). E1-a 검증은 AVFoundation 디코딩과 자체 파서만 썼다.
- **GPU 세부 사양, Metal 기능 세트**: 확인하지 않았다.
- **저장소 볼륨 대소문자 구분 여부**: 확인하지 않았다.

## 참고

- 이 Mac 하나에서의 관찰값이므로 다른 개발 기기나 사용자 기기의 환경을 대표하지 않는다.
- 도구 설치나 시스템 설정 변경은 하지 않았다.
