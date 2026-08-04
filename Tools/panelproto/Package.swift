// swift-tools-version: 6.0
import PackageDescription

// Живой прототип панели софтфона.
//
// Отдельный пакет, а не цель в приложении: прототип показывает согласованную
// компоновку на заглушках и не должен ни зависеть от `AppModel`, ни попадать в
// сборку продукта. Xcode-проект его не подключает, запуск только через
// `swift run --package-path Tools/panelproto`.
//
// Платформа .v14, а не .v10_15: прототип живёт на машине разработчика и нужен
// ради компоновки. Сама компоновка при этом намеренно не использует ничего,
// чего нет на Catalina, — ни `Layout`, ни `MenuBarExtra`, ни `Grid`.
let package = Package(
    name: "panelproto",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "panelproto", targets: ["panelproto"])
    ],
    targets: [
        .executableTarget(
            name: "panelproto",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
