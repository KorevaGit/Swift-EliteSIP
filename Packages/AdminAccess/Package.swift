// swift-tools-version: 6.0
import PackageDescription

// AdminAccess — административный доступ к закрытой части настроек: проверочное
// значение пароля, код восстановления и состояние открытой сессии.
//
// Отдельный пакет по той же причине, что и CallGuard: криптографию нельзя
// принимать глазами. Проверить, что чужой пароль не подходит, что подделанный
// файл настроек не открывает режим и что код восстановления возвращает ровно
// ту строку, которую положили, можно только тестом.
//
// Внутри — чистая логика: без AppKit, без Keychain, без файлов. Соли и время
// приходят снаружи, чтобы тест мог их задать.
let package = Package(
    name: "AdminAccess",
    // Отказы пакета показываются человеку, поэтому язык у него свой: строки
    // живут рядом с кодом, который их порождает, а не в приложении, которому
    // пришлось бы повторять разбор ошибок ради подписи.
    defaultLocalization: "ru",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "AdminAccess", targets: ["AdminAccess"])
    ],
    targets: [
        .target(
            name: "AdminAccess",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AdminAccessTests",
            dependencies: ["AdminAccess"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
