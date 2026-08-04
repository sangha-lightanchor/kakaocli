// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "kakaocli",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "kakaocli", targets: ["KakaoCLI"]),
        .library(name: "KakaoCore", targets: ["KakaoCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "KakaoCLI",
            dependencies: [
                "KakaoCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "KakaoCore",
            dependencies: ["CSQLCipher"],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Security"),
            ]
        ),
        .systemLibrary(
            name: "CSQLCipher",
            pkgConfig: "sqlcipher",
            providers: [.brew(["sqlcipher"])]
        ),
        .testTarget(
            name: "KakaoCoreTests",
            dependencies: ["KakaoCore"]
        ),
    ]
)
