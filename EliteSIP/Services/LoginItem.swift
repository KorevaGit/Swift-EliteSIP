import Foundation
import ServiceManagement

/// Запуск вместе с системой — «Запускать с Windows» Windows-клиента 1.0.4.
///
/// Состояние хранится не в настройках, а у системы: оператор может убрать
/// приложение из «Объектов входа» руками, и переключатель обязан показать
/// правду, а не то, что мы когда-то записали.
///
/// - macOS 13 и новее — `SMAppService.mainApp`: приложение видно в «Системных
///   настройках → Основные → Объекты входа», там же его можно выключить.
/// - Catalina–Monterey — агент в `~/Library/LaunchAgents`: другой дороги без
///   вспомогательного приложения в бандле там нет. Агент зовёт `open`, а не
///   сам исполняемый файл, поэтому запущенное приложение не получит двойника.
@MainActor
enum LoginItem {

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    /// - Returns: текст ошибки для журнала или `nil`, если получилось.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        do {
            if enabled {
                try FileManager.default.createDirectory(
                    at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let plist: [String: Any] = [
                    "Label": agentLabel,
                    "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                    "RunAtLoad": true,
                    "LimitLoadToSessionType": "Aqua",
                ]
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: agentURL, options: .atomic)
            } else if FileManager.default.fileExists(atPath: agentURL.path) {
                try FileManager.default.removeItem(at: agentURL)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static let defaultAppliedKey = "EliteSIPLoginItemDefaultApplied"

    /// Включено по умолчанию, как «Запускать с Windows»: один раз на машине.
    /// Дальше решает оператор — выключенное руками больше не включается.
    ///
    /// Не в Debug: `SMAppService.mainApp` записал бы в «Объекты входа» сборку
    /// из папки проекта вместо установленного приложения.
    static func applyDefaultIfNeeded(log: (String) -> Void) {
        #if !DEBUG
        guard !UserDefaults.standard.bool(forKey: defaultAppliedKey) else { return }
        UserDefaults.standard.set(true, forKey: defaultAppliedKey)
        guard !isEnabled else { return }
        if let problem = setEnabled(true) {
            // не переводится: строка журнала
            log("запуск с системой не включён: \(problem)")
        }
        #endif
    }

    private static var agentLabel: String {
        "\(Bundle.main.bundleIdentifier ?? "com.elite.EliteSIP").login"
    }

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }
}
