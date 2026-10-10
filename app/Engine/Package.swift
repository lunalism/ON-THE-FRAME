// swift-tools-version:6.0
// ON THE FRAME 편집기 엔진(M1): 미디어 검사, 불변 타임라인과 편집 기록, 프리뷰·내보내기 공유 composition 구성, 샌드박스 호환 내보내기.
// 실험 코드(E1Core·E2Core)에서 검증된 규칙을 앱 범위에 맞게 다시 썼다(app/README.md). 검증 도구·테스트는 실험의 생성 fixture와 측정 코드를 재사용한다.
import PackageDescription

let package = Package(
    name: "OnTheFrameEngine",
    // M1 잠정 배포 대상(A-005). 제품의 최소 macOS 결정(O-01)이 아니다.
    platforms: [.macOS(.v15)],
    products: [.library(name: "OnTheFrameEngine", targets: ["OnTheFrameEngine"])],
    dependencies: [.package(path: "../../experiments/e2-4k")],
    targets: [
        .target(name: "OnTheFrameEngine", swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]),
        // 개발 검증 전용(앱 번들에 들어가지 않음): 생성 fixture, 내보낸 파일의 프레임·소리 판정.
        // 실험의 생성 fixture(SourceVideoSpec)와 프레임 측정(E2Metrics)을 재사용한다.
        .target(name: "OTFDevSupport", dependencies: ["OnTheFrameEngine", .product(name: "E2Core", package: "e2-4k")],
                swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]),
        .executableTarget(name: "otf-dev", dependencies: ["OTFDevSupport", .product(name: "E2Core", package: "e2-4k")], swiftSettings: [.unsafeFlags(["-strict-concurrency=complete"])]),
        .testTarget(name: "OnTheFrameEngineTests", dependencies: ["OnTheFrameEngine", "OTFDevSupport", .product(name: "E2Core", package: "e2-4k")]),
    ],
    swiftLanguageModes: [.v5]
)
