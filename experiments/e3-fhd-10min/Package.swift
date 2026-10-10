// swift-tools-version:6.0
// E3-1 실험 하네스: 10분 FHD 타임라인(짧은 생성 소스 반복, 실제 디코딩·합성, 컷·자막·스펙트럼), 프리뷰·내보내기, 자원 측정.
// 제품 코드가 아니다. E1Core·E2Core·E2Judge를 경로 의존성으로 재사용한다(패키지 복제 없음).
import PackageDescription

let strict: [SwiftSetting] = [.unsafeFlags(["-strict-concurrency=complete"])]

let package = Package(
    name: "E3FHD10Min",
    // 실험용 배포 대상. 제품의 최소 macOS 결정(O-01)이 아니다.
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../e1-fhd"), .package(path: "../e2-4k")],
    targets: [
        .target(name: "E3Expect", swiftSettings: strict),
        .target(name: "E3Core", dependencies: [.product(name: "E1Core", package: "e1-fhd"), .product(name: "E2Core", package: "e2-4k"),
                                               .product(name: "E2Judge", package: "e2-4k")], swiftSettings: strict),
        .target(name: "E3Judge", dependencies: ["E3Core", "E3Expect", .product(name: "E2Core", package: "e2-4k")], swiftSettings: strict),
        .executableTarget(name: "e3", dependencies: ["E3Core", "E3Expect", "E3Judge", .product(name: "E1Core", package: "e1-fhd"),
                                                    .product(name: "E2Core", package: "e2-4k"), .product(name: "E2Judge", package: "e2-4k")],
                          swiftSettings: strict),
        .executableTarget(name: "e3preview", dependencies: ["E3Core", "E3Expect", "E3Judge", .product(name: "E1Core", package: "e1-fhd"),
                                                           .product(name: "E2Core", package: "e2-4k"), .product(name: "E2Judge", package: "e2-4k")],
                          swiftSettings: strict),
    ],
    swiftLanguageModes: [.v5]
)
