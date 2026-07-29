// swift-tools-version: 6.0
import PackageDescription

// MediaCore — всё, что касается звука и RTP. На M0 здесь только кодеки G.711:
// они чистые функции без состояния, полностью тестируемые, и именно от них
// зависит первый живой звонок в M2.
let package = Package(
    name: "MediaCore",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "MediaCore", targets: ["MediaCore"])
    ],
    dependencies: [
        .package(path: "../Compat")
    ],
    targets: [
        .target(
            name: "MediaCore",
            dependencies: [.product(name: "Compat", package: "Compat")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MediaCoreTests",
            dependencies: ["MediaCore", .product(name: "Compat", package: "Compat")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
