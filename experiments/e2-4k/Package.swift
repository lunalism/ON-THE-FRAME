// swift-tools-version:6.0
// E2 실험 하네스: 짧은 4K 컷 편집(실제 소스 영상 디코딩·합성, 프리뷰, 내보내기). 제품 코드가 아니다.
// E1의 출력 보호·내보내기 제어·스펙트럼 분석·식별 정보는 경로 의존성으로 재사용한다(experiments/e1-fhd의 E1Core).
import PackageDescription

let strict: [SwiftSetting] = [.unsafeFlags(["-strict-concurrency=complete"])]

let package = Package(
    name: "E24K",
    // 실험용 배포 대상. 제품의 최소 macOS 결정(O-01)이 아니다.
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../e1-fhd")],
    targets: [
        .target(name: "E2Core", dependencies: [.product(name: "E1Core", package: "e1-fhd")], swiftSettings: strict),
        .target(name: "E2Expect", swiftSettings: strict),
        .target(name: "E2Judge", dependencies: ["E2Core", "E2Expect", .product(name: "E1Core", package: "e1-fhd")], swiftSettings: strict),
        .executableTarget(name: "e2", dependencies: ["E2Core", "E2Expect", "E2Judge", .product(name: "E1Core", package: "e1-fhd")], swiftSettings: strict),
        .executableTarget(name: "e2preview", dependencies: ["E2Core", "E2Expect", "E2Judge", .product(name: "E1Core", package: "e1-fhd")], swiftSettings: strict),
        .testTarget(name: "E2CoreTests", dependencies: ["E2Core", "E2Expect", .product(name: "E1Core", package: "e1-fhd")]),
    ],
    swiftLanguageModes: [.v5]
)
