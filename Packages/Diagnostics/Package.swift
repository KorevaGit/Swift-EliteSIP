// swift-tools-version: 6.0
import PackageDescription

// Diagnostics — файловый журнал и всё, что нужно, чтобы его можно было отдать.
//
// Отдельный пакет, а не файл в приложении, по той же причине, по которой ими
// стали CallGuard и MediaCore: здесь есть что проверять без AppKit. Маскирование
// секретов и ротация — чистые функции от строки и от состояния каталога, и
// проверяются они тестом, а не запуском софтфона на сутки.
//
// Цена ошибки тут несимметричная. Незамаскированный ответ Digest в журнале — это
// пароль от SIP-аккаунта в файле, который оператор по инструкции отправляет в
// поддержку через мессенджер. Сломанная ротация — это заполненный диск на
// рабочем месте через полгода. Ни то, ни другое не всплывает на разработке.
//
// О SIP пакет не знает ничего и уровни журнала принимает строкой: иначе
// зависимость пошла бы в обратную сторону, а маскировать надо в том числе то,
// что печатает не SIPCore.
let package = Package(
    name: "Diagnostics",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "Diagnostics", targets: ["Diagnostics"])
    ],
    targets: [
        .target(
            name: "Diagnostics",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DiagnosticsTests",
            dependencies: ["Diagnostics"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
