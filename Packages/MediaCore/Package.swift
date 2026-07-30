// swift-tools-version: 6.0
import PackageDescription

// MediaCore — всё, что касается звука и RTP. На M0 здесь только кодеки G.711:
// они чистые функции без состояния, полностью тестируемые, и именно от них
// зависит первый живой звонок в M2.
let package = Package(
    name: "MediaCore",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "MediaCore", targets: ["MediaCore"])
    ],
    dependencies: [
        .package(path: "../Compat")
    ],
    targets: [
        // Прослойка на Objective-C ради одной функции: поймать NSException.
        // AVAudioEngine сообщает несовпадение формата с железом исключением, а
        // не ошибкой, и Swift такое не ловит — без прослойки гонка при смене
        // устройства роняет процесс.
        .target(name: "AudioObjCTrap"),
        .target(
            name: "MediaCore",
            dependencies: [
                "AudioObjCTrap",
                .product(name: "Compat", package: "Compat"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MediaCoreTests",
            dependencies: ["MediaCore", .product(name: "Compat", package: "Compat")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
