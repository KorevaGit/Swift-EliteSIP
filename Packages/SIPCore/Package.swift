// swift-tools-version: 6.0
import PackageDescription

// SIPCore не знает ни про AppKit, ни про SwiftUI, ни про аудио. Только протокол.
// Благодаря этому весь разбор сообщений и логика транзакций гоняется через
// `swift test` за секунды, без запуска приложения и без живого Asterisk.
let package = Package(
    name: "SIPCore",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "SIPCore", targets: ["SIPCore"])
    ],
    dependencies: [
        .package(path: "../Compat")
    ],
    targets: [
        .target(
            name: "SIPCore",
            dependencies: [.product(name: "Compat", package: "Compat")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SIPCoreTests",
            dependencies: ["SIPCore", .product(name: "Compat", package: "Compat")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
