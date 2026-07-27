// swift-tools-version: 6.0
import PackageDescription

// MediaCore — всё, что касается звука и RTP. На M0 здесь только кодеки G.711:
// они чистые функции без состояния, полностью тестируемые, и именно от них
// зависит первый живой звонок в M2.
let package = Package(
    name: "MediaCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MediaCore", targets: ["MediaCore"])
    ],
    targets: [
        .target(
            name: "MediaCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MediaCoreTests",
            dependencies: ["MediaCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
