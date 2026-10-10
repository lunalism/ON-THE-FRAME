// swift-tools-version:6.0
// E1 실험 하네스(E1-a 헤드리스 내보내기, E1-b AVPlayer 프리뷰). 제품 코드가 아니다.
import PackageDescription

// 엄격한 동시성 검사를 켜서 Sendable 문제를 경고로 모두 드러낸다(언어 모드는 Swift 5).
let strict: [SwiftSetting] = [.unsafeFlags(["-strict-concurrency=complete"])]

let package = Package(
    name: "E1FHD",
    // 실험용 배포 대상. 제품의 최소 macOS 결정(O-01)이 아니다.
    platforms: [.macOS(.v15)],
    // E2(experiments/e2-4k)가 경로 의존성으로 E1Core를 재사용한다(2026-10-10, A-003). 동작 변경 없음.
    products: [.library(name: "E1Core", targets: ["E1Core"])],
    targets: [
        .target(name: "E1Core", swiftSettings: strict),
        .target(name: "E1Expect", dependencies: ["E1Core"], swiftSettings: strict),
        .executableTarget(name: "e1", dependencies: ["E1Core", "E1Expect"], swiftSettings: strict),
        .executableTarget(name: "e1preview", dependencies: ["E1Core", "E1Expect"], swiftSettings: strict),
        .testTarget(name: "E1CoreTests", dependencies: ["E1Core"]),
    ],
    swiftLanguageModes: [.v5]
)
