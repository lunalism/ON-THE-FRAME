# 동일 프로젝트 정지 프레임 parity

**2026-11-07 · SP-4A-22 — HARNESS VALIDATION PASS.** SP-4A-21 수정본의 증분 Debug 빌드와 A–J 검증을 마쳤다. 119→120과 원본 15개 정지 프레임을 다시 통과했다. 다음 단계는 여섯 후보 파일의 게시 전 재감사다.

승인된 이전 SDK 모듈 캐시 한 곳에서 PCM 143개와 modules.timestamp를 삭제했다. 관리량 172,452 KiB 감소, 호스트 가용 공간 172,476 KiB 증가를 관측했다. 기존 scratch와 서명 앱을 보존했다. 증분 빌드는 exit 0이었다.

A–C는 생성 fixture의 동일 UUID 재개방과 새 세션에서 확인했다. 실행 중인 시험 앱에 디버거로 제3자 훅을 주입한 결과 설치가 구조화된 FAIL로 거부됐다. 원래 출력 해제 후에도 같은 제3자 소유 UUID를 직접 읽었다. D–H의 JSON 변형 14개 모두 구조화된 FAIL을 남겼다. 종료가 승인되지 않은 격리 앱은 보고서 작성과 생존 확인 뒤 감시기가 해당 PID에 SIGTERM을 보냈다. I는 원본 참조와 359 ready-empty를 통과했고 J의 자막 래스터 누락 및 스펙트럼 이미지 객체 불일치는 각각 의도대로 실패했다.

양성 회귀는 119 SLOW, 120 FAST, 전체 15/15 및 소유 자원 해제를 확인했다. 경계·전체 실행의 RSS 증가 표본은 185,632·217,888 KiB였다. 21회 전체에서 가장 큰 관측 증가는 디버거 주입 실행의 324,976 KiB였다. 순간 최대값과 장시간 메모리는 미측정이다. 증거는 ignored `app/selftest-work/sp4a22/`에 보존했다. 독립 DFT와 H.264 디코딩은 SP-4A-16 증거를 재사용했다. 연속 재생·일반 색/알파 parity·물리 화면/청취·Release·소유자 수동 수락은 미완료다.

**2026-11-07 · SP-4A-21 — PATCH READY — TESTS DEFERRED.** Debug 하네스의 교체 관찰자 설치와 result.json 검증을 수정했다. 빌드 시작 여유 부족으로 새 패치의 실행 검증과 게시 판정은 보류한다.

교체 시험은 다음 프로젝트 세션·fixture URL·프로젝트 UUID를 확인하고, 기다리기 전의 세대와 view, 적용을 관측한 새 item을 설치 직전에 재확인한다. MainActor에서 슬롯이 비었거나 원래 view에 실행 소유 훅이 남은 경우에만 sentinel을 설치한다. 다른 소유자는 명시적 FAIL로 보존하고, 해제 시 원래 view와 sentinel UUID를 사용한다. 참조는 Decodable로 읽고 전체 15개 키와 행별 유한 Float 64개를 먼저 검증한다. 디코딩·검증 오류는 기존 구조화된 FAIL 보고 경로를 사용한다.

정적 확인은 Debug Swift 구문 파싱, 원본 참조의 JSON 형태·값 확인, diff 공백 검사다. 관리 여유 1,013,028 KiB는 빌드 시작 하한보다 35,548 KiB 적다. SP-4A-19의 15/15는 이전 버전의 증거다.

다음 검증은 독립된 시험 폴더에서 수행한다. A–C는 제3자 소유 훅을 먼저 설치한 경우의 거부·동일 훅 보존, 같은 UUID를 재개방한 새 세션 및 기존 훅 정리 뒤 소유자 유지를 검사한다. D–H는 고정 원본을 보존한 별도 입력에서 배열·null·스칼라 루트, bands 누락·잘못된 타입, 누락·초과 프레임, 63/65개 원소, 문자열·불리언·null·비유한 값 및 Float 범위 초과를 주고 구조화된 FAIL과 오류 필드를 확인한다. I–J는 원본 유효 참조 통과 및 기존 자막 래스터 누락·발행 객체 불일치의 FAIL을 확인한다. 이후 119→120, 전체 15개 PTS·마커·소스·bands·레이어·자막 경계, 359 ready-empty 및 소유 자원 해제를 같은 한도로 검증하고 재감사한다.

**2026-11-07 · SP-4A-20 — 게시 보류.** SP-4A-19의 소유 출력 정리, 필수 래스터 실패 판정, 15/15 회귀 기록을 재확인했다. 교체 시험에서 새 세션의 관찰자 슬롯을 덮어쓸 수 있는 경로와 기준 JSON 형식 오류 시 강제 캐스팅 종료가 남았다. 교체 시험은 비동기 대기 뒤 현재 view에 sentinel을 설치하기 전에 예상 fixture 세션과 기존 슬롯 소유자를 확인하지 않는다. replacementIntact는 설치 이후의 상태를 비교한다. 기준 result.json은 네 고정 해시 대상에 포함되지 않으므로 구조 오류를 던지는 진단 실패로 처리해야 한다. 이번 재감사에서는 앱을 실행하지 않았다.

## SP-4A-19 · Debug 하네스 소유권 회귀

SP-4A-18에서 확인한 공유 저장소 종료 문제를 Debug 경로 안에서 수정했다. MainActor에서 활성 UUID 하나만 허용하고 최초 빈 세션에서 고정 fixture를 연다. 수락된 프레임은 해당 실행·프로젝트·세션·세대·view·item과 seek token이 일치해야 한다. 해제 시 원래 item의 측정 출력과 원래 overlay의 동일 소유자 훅만 제거한다. 자막 재연결은 현재 소유권이 일치할 때만 한다. 하네스에서 공유 scope 전체 해제와 discard 승인을 제거했다. 세션 교체는 제품의 기존 프로젝트 교체 경로가 scope를 처리한다. 소유권을 잃으면 하네스가 종료를 요청하지 않는다.

교체 시험은 일회용 앱에서 같은 고정 fixture를 다시 열었다. 중복 run 거부, 원래 출력 제거, 교체 세션의 scope 목록·출력 목록·별도 관찰자 보존, 옛 콜백 거부와 앱 생존을 확인한 뒤 외부 감시기가 해당 시험 프로세스만 종료했다. 가시 자막 모델 래스터 누락 및 스펙트럼 객체 불일치는 각각 프레임 0에서 의도대로 FAIL이었다. 불일치 시험에서 픽셀·사각형 비교 자체는 참이었다. 359는 정상 ready 결과, 빈 모델층 contents·제로 사각형 및 기준 bands를 확인해 통과했다.

독립된 119→120 회귀와 전체 15/15는 CAPTURE PASS였고 각 정상 종료에서 소유 출력·훅 해제를 확인했다. 전체 15프레임 실행의 앱 RSS 표본은 169개, 첫 표본 대비 최대 증가 211,776 KiB였다. 이 수치는 짧은 생성 fixture의 관측치다. 순간 최대·장시간 메모리·물리 화면과 청취는 미검증이다. SP-4A-16의 독립 DFT와 MP4 ROI는 과거 증거로 유지한다. 실제 sandbox 권한 철회 시험 및 소유자 수락은 미완료다. 이번 증거는 ignored `app/selftest-work/sp4a19/`에 보존했다.

## SP-4A-18 감사 · 2026-11-07

**기능 증거 15/15, 게시 보류.** Debug 측정 출력 추가·제거에 제품의 자막 동기층 재연결 처리를 맞췄다. SP-4A-13은 다섯 프레임 통과 후 120에서 멈췄다. SP-4A-14에서 PTS 4초, 스펙트럼 120 발행 뒤에도 기대 FAST 대신 SLOW가 15초와 추가 관찰 1초 동안 보였다. SP-4A-15가 누락된 재연결을 지목했고 SP-4A-16 수정 뒤 같은 15초 조건에서 119 SLOW와 120 FAST가 각각 약 22 ms에 확인됐다. 제품 자막 타이밍은 수정하지 않았다.

SP-4A-16·17 양쪽 모두 SLOW(0, 1, 30, 60, 119), FAST(120, 121, 150, 180, 239), MEDIUM(240, 241, 270, 300, 359)에서 현재 seek의 PTS·마커·자막 presentation과 z-order를 확인했다. 64 bands는 export 기록과 같고 선택 소스 중심은 (k+30)×1600이다. 359의 ready-empty는 기준과 일치했다. 활성 spectrum 이미지와 자막 모델 래스터·위치는 공통 렌더러 기준과 비교했다. 독립 DFT는 60/180/300에서 220/440/880 Hz와 band 33/42/52를 확인했다. H.264/AAC 출력의 영상 PTS 360개와 표본 마커 Y 오차 0, 자막·스펙트럼 ROI의 오버레이 신호를 확인했다. ROI 차이를 Preview 색 오차로 해석하지 않는다.

SP-4A-16은 앱 RSS 표본 누락으로 PARTIAL이었다. SP-4A-17은 실제 앱 PID와 시작 신원을 대조해 경계·전체에서 114·174개 표본, 첫 RSS 대비 증가 186,480·215,152 KiB를 관측했다(시험 기준 524,288 KiB 미만). 첫 32 KiB는 기동 초기에 읽힌 값이다. 첫 표본 전이나 표본 사이의 순간 최고와 장시간 메모리는 미측정이다.

**게시 차단.** run의 출력 해제는 캡처한 item을 사용하고 자막 재연결은 세션·세대·view·item 검사를 통과해야 한다. 그러나 함수 바깥 defer는 현재 previewHost의 훅을 지우고 현재 공유 저장소의 모든 scope를 닫은 뒤 discard 승인을 설정하고 앱을 종료한다. await 도중 프로젝트나 view가 교체되거나 중복 실행되면 다른 실행 또는 프로젝트에 영향을 줄 수 있다. 설치한 훅과 정리를 실행 소유권에 묶고 교체·중복 진입을 검증해야 한다. 또한 visible 자막의 모델 CGImage가 없으면 rasterExact 검사 없이 통과할 수 있다. 실제 기록에는 각 visible 행의 rasterExact가 있다.

미완료 범위는 연속 12초 재생 parity, BGRA/420v 색·알파 동등성, 물리 화면·청취, 전체 Release, 장시간 export, native finishWriting hang 복구, 실제 sandbox 접근 철회, 일반 spectrum export 활성화 및 소유자 수동 수락이다. Stage 4는 진행 중이다.

## SP-4A-10 당시 기록 (PARTIAL)


2026-11-06. 기준 `feature/subtitles`, HEAD/upstream `ecce1545ece47da26b8acbedb521b701405f2414`. **PARTIAL — 하네스 초안, 컴파일·실행 미검증. OWNER MANUAL DEFERRED — NOT PASS.**

## 범위와 변경

Debug 명시적 `-OTFStillFrameParityTest` 진입점과 `StillFrameParitySelfTest.swift`를 추가했다. PausedSpectrumOverlay의 기존 수락·게시 뒤에 optional Debug 관찰 훅을 추가하며 원래 반환 선택/그리기/취소 동작은 바꾸지 않는다. 훅은 이 시험만 설치하고 종료 시 해제한다. 일반 spectrum export 거부, 이미지 gate, schema, finalization 구현은 불변이다.

하네스 초안은 새 작업 폴더의 `fixture-path.txt`를 읽고 지정 프로젝트·WAV·영상·기존 MP4의 고정 SHA를 검사한다. 프로젝트를 저장하거나 UUID를 재생성하지 않는다. 실제 project open과 준비 뒤 snapshot/session/generation/seek token, AVPlayerItemVideoOutput PTS·영상 marker, 실제 spectrum publication/bands/raster, subtitle presentation opacity·내용·geometry·z-order를 프레임별로 기록한다. export result.json의 band 참조와 공통 renderer의 동등 raster 비교는 shared-code consistency이며 독립 renderer 증명이 아니다. CALayer.render로 영상 픽셀을 얻었다고 주장하지 않는다. 물리 화면 및 decoded RGB/YUV parity는 UNCONFIRMED다.

요청 프레임은 0,1,30,60,119,120,121,150,180,239,240,241,270,300,359. **15개 모두 NOT RUN**, Step A 실제 앱 로딩/seek/PTS도 미실행이다. 15초 준비 한도는 초안 코드에만 있으며 검증된 결과가 아니다. 잘못된 identity/readiness에서 후속 비교를 진행하지 않도록 한다.

## 원본 확인

SP-4A-01 `app/selftest-work/sp4a01/color/`의 원본 4개는 시작/종료 전체 SHA가 사용자 고정값과 일치했다. project UUID `0F3F7EFB-0FB0-4141-A049-F3BD438D9492`, 형식8, 360프레임/30fps. 프로젝트·WAV·video·spectrum MP4 수정 없음. 기존 export/DFT/MP4 decode 결과는 과거 증거이며 이번에 재실행하지 않았다.

## 빌드 중단과 자원

기존 SP3C239App 산출물을 같은 APFS scratch 안의 별도 SP4A10App 경로로 copy-on-write 복제했다. 원본 signed 앱 보존. 단일 job Debug 빌드1회는 이동한 경로에서 SDK 모듈을 다시 생성했으며 scratch 여유50,000KiB 중지 조건에 도달해 감독 프로세스가 xcodebuild를 종료했다. **exit −15, BUILD INTERRUPTED.** 새 하네스 컴파일·링크·서명·앱 실행 확인에 도달하지 않았다. 기존 CoreSimulator 버전 진단도 로그에 있으나 이번 중단 이유는 scratch 여유다.

시작 관리량19,521,032KiB. 빌드 감시 최고19,662,508KiB, 최저 관측 scratch 여유36,392KiB. 2초 간격 감시는 순간 상한 보장이 아니며50,000KiB 선을 넘어 여유가 더 줄었다. 전체20GiB 한도는 넘지 않았다. 로그/결과는 ignored `app/selftest-work/sp4a10/build.log`, `build-result.json`에 보존했다. capture 출력0, 새 MP4/fixture/디스크 이미지0. 실패 빌드·캐시·앱·원본·이미지/mount를 삭제하거나 원복하지 않았다.

## 다음 작업

정확한 증분 빌드 비용과 기존 이미지 여유를 다시 조사한 뒤 별도 자원 확보/빌드 재개 작업이 필요하다. 이번에는 다른 경로로 재시도하지 않는다. 다음 검증은 우선 Step A project open/identity/seek/PTS이며, 통과 후 실제 layer15개 및 FFT/자막/ROI로 진행한다. 현재 초안은 실행 전 타입 검사와 캡처 해석 검증이 필요하다. 전체화면·lossy 색차·독립 renderer·물리 화면/청취·연속 프리뷰·native hang 복구·Release/장시간 수락은 미완료다.

staging/commit/push, public activation, schema/owner-data 변경 없음. Stage4 완료를 주장하지 않는다.
