// swift-tools-version: 6.0
import PackageDescription

// PanelLink — то, что приложение читает у панели: ключ активации, пакет с
// учётными данными и подписанный файл предустановок.
//
// Отдельный пакет по той же причине, что AdminAccess и CallGuard: криптографию
// нельзя принимать глазами. Что чужой ключ не открывает пакет, что подделанный
// байт ломает подпись файла предустановок и что распечатанное совпадает с тем,
// что положила панель, — проверяется тестом, а не чтением.
//
// Внутри — чистая логика: ни сети, ни файлов, ни AppKit. Байты приходят
// снаружи, чтобы тест мог подать свои. Опрос канала и применение настроек
// живут в приложении.
//
// Границу «что панель, а что машина» задаёт elitesip-site/docs/CONTRACT.md.
let package = Package(
    name: "PanelLink",
    // Отказы пакета показываются человеку — тот же довод, что у AdminAccess:
    // строки живут рядом с кодом, который их порождает.
    //
    // `en`, хотя исходники русские: это язык на случай, когда системе не подошёл
    // ни один из наших.
    defaultLocalization: "en",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "PanelLink", targets: ["PanelLink"])
    ],
    targets: [
        .target(
            name: "PanelLink",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PanelLinkTests",
            dependencies: ["PanelLink"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
