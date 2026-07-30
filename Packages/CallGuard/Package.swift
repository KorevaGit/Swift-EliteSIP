// swift-tools-version: 6.0
import PackageDescription

// CallGuard — защита приёма вызова от автокликеров. Отдельный пакет, потому что
// это основная причина существования приложения, и проверять её надо тестами, а
// не глазами: в AppKit-коде окна ни случайную позицию, ни путь курсора, ни
// отсев синтетических нажатий воспроизводимо не проверить.
//
// Внутри — только чистая логика: без AppKit, без таймеров, без глобального
// времени. Генератор случайных чисел и момент времени приходят снаружи.
let package = Package(
    name: "CallGuard",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "CallGuard", targets: ["CallGuard"])
    ],
    dependencies: [
        .package(path: "../Compat")
    ],
    targets: [
        .target(
            name: "CallGuard",
            dependencies: [.product(name: "Compat", package: "Compat")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CallGuardTests",
            dependencies: ["CallGuard", .product(name: "Compat", package: "Compat")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
