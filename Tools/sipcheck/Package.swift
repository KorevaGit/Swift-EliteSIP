// swift-tools-version: 6.0
import PackageDescription

// Консольная проверка клиента против живого Asterisk.
//
// Отдельный пакет, а не цель внутри SIPCore: инструменту нужны оба пакета
// сразу, а связывать SIPCore с MediaCore ради него нельзя — они намеренно
// ничего друг о друге не знают. Xcode-проект этот пакет не подключает, он
// запускается только через swift run.
let package = Package(
    name: "sipcheck",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "sipcheck", targets: ["sipcheck"])
    ],
    dependencies: [
        .package(path: "../../Packages/SIPCore"),
        .package(path: "../../Packages/MediaCore"),
    ],
    targets: [
        .executableTarget(
            name: "sipcheck",
            dependencies: [
                .product(name: "SIPCore", package: "SIPCore"),
                .product(name: "MediaCore", package: "MediaCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
