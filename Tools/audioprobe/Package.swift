// swift-tools-version: 6.0
import PackageDescription

// Замеры аудиотракта на живой машине.
//
// Отдельный пакет, как и sipcheck: юнит-тесты проверяют логику, а поведение
// CoreAudio с настоящей гарнитурой — нет. Ни AirPods, ни переключение
// устройства на ходу в тестах не воспроизводятся, а понять, что именно делает
// система, надо до того, как писать под это код.
let package = Package(
    name: "audioprobe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "audioprobe", targets: ["audioprobe"])
    ],
    dependencies: [
        .package(path: "../../Packages/MediaCore")
    ],
    targets: [
        .executableTarget(
            name: "audioprobe",
            dependencies: [
                .product(name: "MediaCore", package: "MediaCore")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
