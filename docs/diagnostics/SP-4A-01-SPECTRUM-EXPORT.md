# SP-4A-01 — 첫 deterministic spectrum MP4 내부 slice

2026-11-06. **FIRST SPECTRUM MP4 PASS — 생성 fixture 자동 검사 범위. OWNER MANUAL DEFERRED — NOT PASS.** 일반 내보내기 기능의 공개 활성화나 Stage 4 전체 완료가 아니다.

## 기준과 범위

브랜치 `feature/subtitles`, 시작/종료 HEAD·upstream·live remote `a8abc89a3433918478ce3957bc71c802e2f63d7b`. main·origin/main·live remote main `44943eadabdf5a37d5242d614e7279813126dfde`. index 비어 있음. 기존 미추적 4개 SHA와 복구 refs 3개 보존. staging/commit/push·소유자 미디어/프로젝트 수정·schema migration 없음.

[SP-3C2-40 계약](SP-3C2-40-EXPORT-CONTRACT.md)에 따라 생성 영상 하나, 선택 WAV 하나(sourceIn=30), spectrum 하나, 자막 셋, 360프레임으로 한정했다. 일반 spectrum export rejection은 유지한다. 새 API는 `#if DEBUG` 안의 internal `ExportService.exportSpectrumSlice`이며 명시적 `enabled=true`와 호출자 지정 시험 deadline이 필요하다. 앱 UI 호출은 없다. 이미지·pure audio·다중 spectrum 경로는 지원하지 않는다.

변경 파일:

- `app/Engine/Sources/OnTheFrameEngine/ExportService.swift`: 내부 진입, 기존 검증/승격 경로 재사용.
- `app/Engine/Sources/OnTheFrameEngine/SubtitleExport.swift`: 비동기 프레임 준비, 기존 420v 합성, 취소/실패 깨우기, 내부 경로 finishWriting 제한.
- `app/Engine/Sources/OnTheFrameEngine/SpectrumExport.swift`: Debug 전용 snapshot/접근 소유권/단일 분석 worker와 공통 frame-overlay 계약.
- `app/scripts/SpectrumExportSliceCheck.swift`: 생성 미디어 통합 검사 CLI.
- `app/scripts/SpectrumExportDFTCheck.py`: 별도 DFT·RMS envelope 참조 검사.
- 이 문서, `docs/ROADMAP.md`, `docs/HANDOFF.md`.

## 실제 encoder 통합

기존 CompositionPlanner의 AVComposition·videoComposition·audioMix를 사용한다. 자막 있는 내보내기는 AVAssetReaderVideoCompositionOutput의 FHD 420v 버퍼를 읽고 AVAssetWriterInputPixelBufferAdaptor에 정확한 `CMTime(value:k,timescale:30)`을 붙인다. 자막 없는 일반 경로는 기존 AVAssetExportSession을 유지한다. spectrum은 두 번째 encoder를 만들지 않고 자막 reader/writer 경로에만 연결한다.

Pump는 k마다 한 detached 비동기 준비 작업만 요청하고, 결과가 돌아오기 전 프레임을 쓰지 않는다. 단일 actor Worker가 immutable Timeline의 선택 lineage/source pieces로 `SpectrumAnalysis.chunks/bands`를 호출한다. 현재 AVPlayer 시각, display link, preview lease/clock/scheduler의 drop 정책을 사용하지 않는다. 준비 실패는 전체 실패이고, nil raster만 명시적인 ready-empty 결과다. 영상 큐는 기다리는 동안 반환하므로 MainActor나 dispatch semaphore를 막지 않는다. 이전 job은 정리 완료까지 전역 1-slot을 유지한다.

동일 `SpectrumFrameRenderer`의 premultiplied BGRA raster/drawRect를 기존 SubtitleFootprint로 변환한다. 순서는 **video → spectrum → subtitle**이며 영상 자체는 RGB로 재변환하지 않는다. 기존 Rec.709 SDR/video-range 420v 정책과 H.264/AAC 설정을 재사용한다. 자막은 기존 FootprintWindow의 반열린 구간을 따른다.

WAV와 영상의 MediaAsset/FileIdentity snapshot을 잡고, job이 획득한 security scope만 해제한다. 초기·각 준비 전후·승격 전 정체를 확인한다. 취소된 준비 작업도 실제 반환 전까지 provider/접근/slot을 보유한다. composition audio는 기존 PCM reader/audioMix → AAC writer 경로다. spectrum FFT는 같은 선택 source pieces·gain 규칙을 사용한다.

## 생성 fixture와 검증

증거 루트는 `app/selftest-work/sp4a01/`이며 Git ignored다. 최종 색차 포함 검사는 `color/`, 앞선 전체 안전성 통과 검사는 `verified/`에 있다. 각 폴더의 `video.mp4`, `selected.wav`, `fixture.ontheframe`, `spectrum.mp4`, `normal.mp4`, `result.json`을 보존한다. `promotion-race.mp4`는 의도적으로 만든 sentinel이며 유효 MP4가 아니다.

- 영상: 1920×1080, 30fps, 12초, 360장. 회색 배경과 각 프레임 번호의 9-bit 영상 표식. 오디오 없는 생성 영상이다.
- WAV: 48kHz·stereo·16-bit·13초. 첫 1초를 trim하고 뒤 12초를 사용한다. 4초씩 220/440/880Hz, envelope 2/4/3Hz, duty 0.7.
- spectrum: 0–360, 64 log bands 20–2000Hz, 90ms Hann, offset 0, floor −60dB, 위쪽 디지털 스타일, baseline y=600/maxHeight=420, RGBA(255,195,50,192).
- 자막: SLOW [0,120), FAST [120,240), MEDIUM [240,360), 흰색 64pt, y=500.
- 경계 포함 픽셀 표본: 0,1,30,60,119,120,121,150,180,239,240,241,270,300,359. 360은 출력 프레임이 아닌 endSession 시각이다.

| 검사 | 자동 결과 |
| --- | --- |
| 비디오/오디오 stream | video 1 H.264/FHD, audio 1 AAC |
| 전체 decode/PTS | 정확히 360장, 모든 PTS=k/30, video duration=12초 |
| 영상 표식 | 모든 360프레임 9-bit 표식 일치(압축 허용 오차 6 이내) |
| 준비 순서 | 정확히 0..<360, 누락/재사용 없음 |
| 인코딩 전 합성 Y/CbCr | 공통 renderer raster를 입력으로 production footprint를 쓰지 않는 별도 수식과 비교, 최대 오차 각각 0 |
| codec 후 Y 비교 | 표본 전체 화면 평균 오차 최대 0.0465022/255 |
| spectrum/subtitle | spectrum 잉크 278,422 표본 화소, 자막과 spectrum 겹침 2,483화소; 자막 우선순위/경계 일치 |
| PCM | sourceIn 1초 반영한 WAV와 최대 오차 0, 576,000 stereo frames |
| AAC decode | 1,152,000 float sample values; frame RMS 오차 최대 0.00197914 (<0.02) |
| 독립 DFT | frame60/180/300 → source90/210/330 → 220/440/880Hz; engine peak band33/42/52 |
| RMS envelope | 각 4초 구간 펄스 8/16/12개로 slow/fast/medium 확인 |
| 일반 자막 export 회귀 | spectrum 제거한 기존 경로 완료, 360장 전체 decode/PTS 통과 |
| gate | 일반 spectrum, enabled=false, 선택 소스 없음, pure audio, 다중 spectrum, image gate-off 거부 |

AAC waveform의 sample-exact 일치는 주장하지 않는다. PCM 비교와 AAC 손실 압축 후 RMS 비교는 별개다. reference DFT는 Python 복소 지수 합으로 계산하며 엔진 FFT를 재사용하지 않는다.

## 취소·실패·원본/출력 보호

기존 ExportService의 source/destination 검증 → 현재 작업 temp → encoded file 검증 → 재검증 → promote 순서를 유지했다. 실패/취소는 현재 temp만 지운다.

- 10% 실패 주입: failed, 기존 성공 출력 SHA 유지.
- 150ms 뒤 Task.cancel: cancelled, 기존 출력 SHA 유지.
- frame 준비 300ms 지연/100ms 제한: 명시적 frame deadline failure, 기존 출력 SHA 유지.
- writer output 위치에 생성 디렉터리를 넣은 실제 writer 초기화 실패: Cannot Save, 기존 출력 SHA 유지.
- 생성 WAV를 임시 이동한 invalid source: 명시적 source identity/readability 실패, 원래 위치 복원 후 미디어/프로젝트 SHA 동일.
- 검증 뒤 destination에 sentinel을 만드는 promotion race: 명시적 거부, sentinel 보존.
- 안전성 검사 temp 경로 5개 모두 반환 뒤 없음. worker slot이 5초 내 해제된 뒤 다음 작업 진행을 검증했다. 실패 직후 worker draining=true도 관측했다.

영상/소리 직렬 큐가 실패를 보도록 깨우고 markAsFinished를 한 번만 수행한다. callback 그룹 종료 뒤 writer/reader를 취소한다. 내부 finishWriting도 취소/남은 job deadline을 연결했다. worker 취소가 비협조적 native I/O를 강제 중단한다는 보장은 없다. OS I/O가 멎는 상황의 강제 종료·모든 finishWriting 취소 타이밍·장기 stress는 이번 시험으로 입증하지 않았다. slot/scope를 먼저 풀어 새 작업과 겹치게 하지 않는다. 생성 로컬 파일 CLI 검사는 실제 sandbox bookmark 승인/OS 접근 철회 수락 시험이 아니며, scope 획득/반납 소유권은 코드 검토와 worker 생명주기 검사 범위다.

## 실행 기록과 재현

현재 Engine Debug 한정 빌드 exit0. Xcode 로그의 기존 CoreSimulator 버전 진단은 있었으나 BUILD SUCCEEDED다. 앱 전체/Release/prototype/WMO 빌드는 하지 않았다. 최종 CLI compile exit0, 통합 검사와 독립 DFT exit0. 새 엔진 동작에 대한 광범위 기존 XCTest 전체 실행은 하지 않았다.

중간 실패를 삭제하지 않았다:

1. 최초 fixture mediaFrames/mediaHasAudio 누락으로 timeline validation 실패(exit1), fixture 생성 수정.
2. 이전 실패 작업이 아직 정리 중일 때 연속 취소 검사를 시작한 실행에서 cancel 단언 실패(exit1). 당시 세부 outcome 미기록으로 원인은 단정하지 않는다. 이후 waitIdle·실제 outcome 기록을 추가했고 draining을 관측, 취소 통과.
3. normal regression reader와 track에 서로 다른 AVURLAsset 인스턴스를 사용한 하네스 NSException(exit−6). 동일 asset 사용으로 수정. 실제 spectrum 출력과 기존 증거 보존.
4. temp 추적 callback 인자 순서의 CLI compile 오류(exit1), Swift 인자 순서 수정 후 exit0.

하네스 재현에는 **새 disposable fixture 폴더**와 생성 WAV가 필요하다. 소유자 파일에 실행하지 않는다. 기존 fixture/결과 폴더에 재실행해 덮어쓰지 않는다. video.mp4가 없으면 CLI가 생성한다. bounded Debug Engine 빌드 산출물의 .swiftmodule/.o를 사용해 다음처럼 컴파일한다(변수는 환경에 맞춰 지정):

```sh
xcrun swiftc -parse-as-library -swift-version 5 -D DEBUG -enable-testing \
  -I "$products" -module-cache-path "$scratch/HarnessCache" \
  app/scripts/SpectrumExportSliceCheck.swift "$products/OnTheFrameEngine.o" \
  -o "$scratch/spectrum-check"
"$scratch/spectrum-check" "$fixture"
python3 app/scripts/SpectrumExportDFTCheck.py "$fixture"
```

이번 실제 빌드/자원 감시 명령은 ignored `build.py`, `run-verified.py`, `run-color.py`와 로그/JSON에 보존했다. 새 빌드 없이 기존 engine 산출물로 하네스를 재컴파일했다. `run-verified` wall93.58초/peakRSS332,208KiB, 최종 `run-color` wall108.09초/peakRSS385,440KiB는 하네스의 표본 Y 버퍼/PCM 참조 등도 포함하는 측정값이며 제품 한도가 아니다.

## 자원·잔여 범위

시작 관리량 19,041,872KiB(18.160GiB), 새 build peak 19,318,268KiB(18.423GiB), 최종 시험 관측 peak19,329,820KiB(18.434GiB), 최종 약18.43GiB/20GiB. 기존 작은 scratch 여유가 부족해 별도 1GiB 한정 APFS sparse image에서 engine만 single-job 빌드했다. backing의 실제 할당량을 한 번만 세며 관리 app/experiments/developer 합계에 포함한다. 기존 이미지·앱·증거·캐시는 삭제하지 않았다. 19.8GiB/남은 scratch50,000KiB 중지 감시를 적용했으며 강제 process memory 제한은 아니다.

분석 캐시는 8초 stereo Float chunk 최대2개, 관측 peak6,144,000bytes, 명시적8MiB 검사다. raster는 최대16MiB 검사(1920×1080 BGRA 상한8,294,400bytes). 한 frame footprint만 보유하며 FHD geometry로 Y/CbCr 인덱스/계수 저장 상한은 논리적으로 약33.18MB, 생성 중 지역 Double 배열4개는 최악66.36MB다(배열 capacity/native decoder/writer 메모리 별도). 이는 전체 process 8MiB 주장이나 모든 스타일의 peakRSS 보장이 아니다.

**OWNER MANUAL DEFERRED — NOT PASS.** 실제 화면/청취 수락, full Release, 일반 영상/길이/채널/스타일 조합, 이미지-spectrum, audio-only black-video, 다중 spectrum, 장시간 취소/저장장치 정지/메모리 stress는 남는다. 10초 step/120초 job은 이번 호출의 잠정 시험 값이며 영구 제품 defaults가 아니다. Stage3C-2의 시작/전환 공백과 기존 preview 제한도 이 작업으로 해결된 것이 아니다.

다음 권고: **SP-4A-02 — 첫 spectrum export checkpoint audit**. 이 변경의 취소/소유권·프레임 합성·증거 재현성을 감사한 뒤 더 넓은 조합을 별도 승인 범위로 제안한다. 공개 export 활성화나 자동 게시를 권고하지 않는다.

최종 `color/spectrum.mp4` SHA-256: `04c346e4edcc1e442eb60cfb9e4a362b47f8d44e7e2dda068131640b421c4745`. 결정적인 프레임/분석 결과를 검증했으며 MP4 container 전체의 byte-identical 재생성은 주장하지 않는다. 기존 역사 evidence12,002개는 보존 snapshot의 size/mtime/inode 대조에서 변화0이었다.


## SP-4A-02 — 게시 체크포인트 감사 (2026-11-06)

**PUBLICATION READY — 이 내부 첫 slice의 게시 후보 감사.** 8개 후보 전체와 SP-4A-01 매니페스트를 대조했다. 감사 시작 시 모든 후보/최종 fixture 해시가 일치했고, 이번에는 이 문서와 ROADMAP/HANDOFF만 수정했다. 엔진3개와 검사2개의 내용/모드는 SP-4A-01 그대로다. index는 비어 있고 예상 밖 tracked 변경·symlink 대체·제품 gate/schema 변경은 없다. 기준 branch/HEAD/upstream/live remote/main 및 복구 refs3개는 위 기록과 같다. 새 제품 구현·staging/commit/push는 없다.

### 구조·안전성 판정

기존 encoder·오디오 mix·승격 규칙을 재사용하며, 범위 내 중대한 정확성/출력 보호 차단 결함을 발견하지 않았다. Timeline/MediaAsset 값 snapshot 및 job 전용 renderer/worker는 이전 project 결과를 공유하지 않는다. k가 next와 일치해야 하며 실패를 ready-empty로 바꾸지 않는다. 늦은 준비 callback은 videoDone 확인으로 버린다. 기존 영상 reader의 PTS≤k/30 표본 펼치기는 유지되고 spectrum 경로에서 strictFrameGrid를 새로 켜지는 않는다. 따라서 모든 가능한 입력 영상의 원본 PTS 일치 보장이 아니라, 이 생성 fixture의 360개 marker 전수 일치 증거다.

합성 전 새 420v의 활성 Y/UV 바이트를 원본에서 복사하고 spectrum, 자막을 순서대로 쓴다. crop/좌표/알파는 공통 renderer/footprint를 사용한다. 디지털 FFT 전체0은 정상 nil raster이고 이전 footprint를 append 뒤 지워 잔상을 방지한다. source unset/missing·coverage 오류는 preflight 실패, 분석/렌더 오류는 throw다. 투명/화면 밖 스타일의 정상 빈 결과와 분석 실패는 다르다. 이번 생성 fixture 밖의 스타일·무음 전용 fault matrix를 새로 실행했다는 뜻은 아니다. 기존 601 입력의709 태깅 한계도 유지한다.

동기 FFT/렌더/footprint 생성은 단일 Worker actor, reader/compositor/writer callback은 전용 직렬 큐에서 수행한다. MainActor 대기/semaphore는 없다. 파일 identity 확인과 AVFoundation native 호출 자체가 무차단이라는 보장은 없다. 현재 job deadline은 encoder pump 시작부터 finishWriting까지이며 planner·사전검증·최종 파일 검증·promotion 전체를 감싼 hard timeout이 아니다. progress callback이 협조하지 않거나 native I/O가 멎는 경우도 완전한 wall-clock 보장 밖이다. 이는 공개 기능/일반 입력 지원으로 확대하지 않는다.

기존 source 경로·symlink 해석·sameFile 검증, 대치 확인, 작업 소유 temp, 실패/취소 시 정리, 승격 직전 재검증, 새 대상 배타적 rename/기존 대상 replace를 유지했다. 추가 분석 작업은 취소 뒤 실제 drain까지 scope/slot을 붙잡는다. 앞선 취소·주입 실패·실제 writer 초기화 실패·timeout·원본 소실·promotion conflict 결과와 기존 보호 테스트 코드를 대조했다. 기존 destination 성공 대치와 hardlink 보호의 엔진 테스트는 코드 검토했으며 이번 재실행은 아니다. 생성 fixture의 원본 소실 시험은 초기 identity/readability 실패를 입증하고, 진행 중 파일 교체/실제 sandbox 권한 철회까지 시험한 것은 아니다. OS reader/writer 객체의 모든 수명 경로를 instrument한 것으로 주장하지 않는다.

### 비교 단계와 새 검사

- **과거 SP-4A-01:** Engine Debug/CLI 컴파일·통합2회·DFT exit0, 일반 자막360장 회귀, 안전성6종 통과. 중간 exit1/−6 기록 보존. 최종 MP4와 fixture/result/DFT 파일 SHA를 이번에 다시 대조했다.
- Y/Cb/Cr 오차0은 **인코딩 전** 합성 버퍼에 대한 것이다. 별도 합성 수식이지만 입력 raster는 공통 엔진 renderer다. 독립 renderer 검증이나 최종 H.264 lossless 결과가 아니다.
- H.264 최종 출력은 전체 decode/PTS/marker, 대표15프레임의 화면 전체 Y 평균 오차 최대0.0465022(8-bit code units) 검사다. 최종 decoded Cb/Cr와 reference의 오차0 검사는 없다. 자막119/120·239/240은 공통 자막 raster를 사용한 pre-encode 비교 및 최종 화면 평균 비교 범위다.
- 독립 DFT는 WAV의 알려진 tone3개를 별도 복소 합으로 계산하고 엔진 peak band와 대조한다. 모든64밴드 수치의 독립 검증은 아니다. RMS pulse 검사는 원본 WAV envelope이며 최종 영상 막대 전체의 독립 rhythm 검증은 아니다.
- PCM은 인코딩 전 composition과1초 trim WAV 비교, AAC는 별도 손실 decode 후 RMS 비교다. sample-exact AAC/H.264를 주장하지 않는다.
- **이번 추가 읽기 검사:** 기존 `color/spectrum.mp4`만 AVAssetReader로 읽었다. H.264 FHD/video1·AAC/audio1, 전체360개 PTS=k/30, 영상/소리 track [0,12), AAC decode576,000 stereo sample frames의 연속 PTS와 끝12초를 확인했다. frame60/180/300의 spectrum색 UV 표본은 각각7,692/7,122/5,488개이며 y범위280–598/278–598/278–598, 허용 geometry밖 색 표본0이었다. 이는 최종 spectrum 존재/수직 배치의 보강 검사이며 정밀 색 일치·preview parity 수락은 아니다.
- 새 작은 읽기 CLI compile2회 exit0. sandbox 실행2회는 AVAssetReader.startReading 실패로 top-level assertion exit133, 동일 상세 바이너리를 승인된 macOS decoder 접근으로 실행한 결과 exit0. 소스/MP4 수정 없이 통과했다. 이 실패를 제품 encoder 실패나 자동 승인 거절로 분류하지 않는다. 원시 기록은 제외된 `app/selftest-work/sp4a02/`에 보존한다. 새 export·Engine/app/Release/prototype/WMO 빌드는 없다.

### 게시 범위·잔여 작업

게시 후보는 위 정확한8개 파일, 모두 일반 파일100644다. 전체 SHA-256과 목적은 SP-4A-02 최종 보고 및 제외된 `app/selftest-work/sp4a02/publication-manifest.json`에 기록한다(문서 자신의 hash를 문서에 넣지 않는다). 생성 MP4/미디어/프로젝트, raw logs, 이 감사의 읽기 도구, 빌드·서명 앱·APFS 이미지·캐시, 기존 .DS_Store/.claude/settings.json은 제외·보존한다. 후보 추가 내용에 개인 절대 경로·자격 증명·바이너리는 없다.

시작 관리량19,325,520KiB(18.430GiB), 추가 읽기 검사 후19,325,544KiB로 약24KiB 증가(문서/최종 매니페스트 전 측정). 기존1GiB scratch와 module cache 재사용, 새 disk image/정리 없음. 20GiB 정책 안이다.

**완료된 내부 첫 slice:** 생성12초 spectrum MP4, frame-indexed 처리, selected-source DFT/시간 매핑, video→spectrum→subtitle 합성, 제한된 취소/출력 보호 자동 검사.

**미완료:** 일반 spectrum 공개 활성화, image-spectrum, audio-only, 다중/겹침 spectrum, full Release 앱, 장시간 내보내기, 실제 sandbox 철회, owner 시각/청취 수락, 최종 preview/export parity 수락. Stage4 전체 완료가 아니다. **OWNER MANUAL DEFERRED — NOT PASS.** 기존 preview timing/UX·large catalog·native I/O·메모리/취소 stress 제한을 보존한다.

제안 commit subject: `Add gated deterministic spectrum MP4 export slice`. 실제 commit/push는 별도 지시가 필요하다. 다음 개발 권고는 현재12초 내부 경로에 대한 **finalizing 취소·진행 중 source 교체·무진행 fault matrix 강화**이며, 기능 범위 확대는 포함하지 않는다.
