import Foundation

/// Какая система на машине — для Spark: семейство и название под версией
/// клиента в списке сотрудников. Уходит заголовками `X-EliteSIP-Platform` и
/// `X-EliteSIP-OS` с каждым запросом канала, как в Windows- и Linux-версиях.
enum MachinePlatform {

    /// `macos` — как ждёт сервер обновлений (`linux`, `windows`, `macos`).
    static let family = "macos"

    /// Название системы: «macOS 15.1.1».
    static let name = headerSafe(osName(ProcessInfo.processInfo.operatingSystemVersion))

    static func osName(_ version: OperatingSystemVersion) -> String {
        let patch = version.patchVersion > 0 ? ".\(version.patchVersion)" : ""
        return "macOS \(version.majorVersion).\(version.minorVersion)\(patch)"
    }

    /// Печатный ASCII до 64 знаков: значение уходит заголовком HTTP.
    static func headerSafe(_ text: String) -> String {
        let printable = text.unicodeScalars.filter { $0.value >= 0x20 && $0.value <= 0x7E }
        return String(String.UnicodeScalarView(printable.prefix(64)))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Проставить оба заголовка.
    static func apply(to request: inout URLRequest) {
        request.setValue(family, forHTTPHeaderField: "X-EliteSIP-Platform")
        if !name.isEmpty {
            request.setValue(name, forHTTPHeaderField: "X-EliteSIP-OS")
        }
    }
}
