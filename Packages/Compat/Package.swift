// swift-tools-version: 6.0
import PackageDescription

// Compat — единственный слой обратной совместимости с macOS 10.15 Catalina.
//
// По плану выпускается одна universal-сборка: срез x86_64 обязан работать на
// Catalina, срез arm64 — на Big Sur и новее. Отдельная legacy-цель не заводится,
// потому что Catalina уже содержит SwiftUI, Network.framework, CryptoKit и
// back-deploy Swift concurrency. Не хватает только API, добавленных после неё,
// и все замены им собраны здесь, а не размазаны по трём пакетам.
//
// Что заменяется и почему именно так:
//
//   Duration и ContinuousClock (macOS 13) — `Interval` и `MonotonicClock`.
//   Ими в проекте меряются таймеры SIP-транзакций и реакция оператора на окно
//   входящего, то есть промежутки, а не даты. Настенные часы для этого не
//   годятся: перевод времени или дрейф NTP сдвинул бы и ретрансмиссию INVITE,
//   и отчёт защиты от автокликеров.
//
//   OSAllocatedUnfairLock (macOS 13) — `UnfairLock`. Под ним аудиотракт:
//   кольцевые буферы захвата и воспроизведения, к которым обращается и поток
//   CoreAudio, и обычный код.
//
// Пакет намеренно ничего не импортирует, кроме Darwin: его линкует и SIPCore,
// который не должен знать ни про AppKit, ни про аудио.
let package = Package(
    name: "Compat",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "Compat", targets: ["Compat"])
    ],
    targets: [
        .target(
            name: "Compat",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CompatTests",
            dependencies: ["Compat"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
