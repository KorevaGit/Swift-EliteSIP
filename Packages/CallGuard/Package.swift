// swift-tools-version: 6.0
import PackageDescription

// CallGuard — защита приёма вызова от автокликеров. Отдельный пакет, потому что
// это основная причина существования приложения, и проверять её надо тестами, а
// не глазами: в AppKit-коде окна ни случайную задержку, ни путь курсора, ни
// отсев досрочных нажатий воспроизводимо не проверить.
//
// Внутри — только чистая логика: без AppKit, без таймеров, без глобального
// времени. Генератор случайных чисел и момент времени приходят снаружи.
let package = Package(
    name: "CallGuard",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CallGuard", targets: ["CallGuard"])
    ],
    targets: [
        .target(
            name: "CallGuard",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CallGuardTests",
            dependencies: ["CallGuard"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
