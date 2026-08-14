// swift-tools-version: 6.0
import PackageDescription

// SIPCore не знает ни про AppKit, ни про SwiftUI, ни про аудио. Только протокол.
// Благодаря этому весь разбор сообщений и логика транзакций гоняется через
// `swift test` за секунды, без запуска приложения и без живого Asterisk.
let package = Package(
    name: "SIPCore",
    // Причина отказа регистрации и причина окончания звонка приходят отсюда и
    // попадают человеку в шапку панели и в историю. Трасса протокола рядом с
    // ними остаётся непереведённой — её читают в журнале, а не в интерфейсе.
    defaultLocalization: "ru",
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
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SIPCoreTests",
            dependencies: ["SIPCore", .product(name: "Compat", package: "Compat")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
