import Combine
import Darwin
import Diagnostics
import Foundation
import MediaCore
import SystemConfiguration

/// Что менялось вокруг приложения за сеанс: сеть и звуковые устройства.
///
/// Перенос `RuntimeDiagnostics` из Windows и Linux 1.0.8. Жалоба «пропал
/// звук» или «отвалилась регистрация» почти всегда совпадает по времени со
/// сменой Wi-Fi, VPN или гарнитуры, а в журнале этого не было: виден был
/// только итог. Теперь каждое изменение пишется в журнал, уходит в журнал
/// машины для Spark и попадает в архив поддержки (`runtime-history.txt`).
///
/// **Сеть** опрашивается раз в 3 с: адреса интерфейсов (`getifaddrs`) и шлюз
/// из `SCDynamicStore`. Подписки здесь нет намеренно — `NWPathMonitor` уже
/// ведёт переподключение, а сравнение снимков дёшево и показывает ровно то,
/// что изменилось, а не «путь обновился».
///
/// **Звук** — без опроса: каталог устройств уже наблюдается моделью
/// (`AppModel.audioCatalog`), здесь только сравнение соседних снимков и выбора
/// в настройках.
@MainActor
final class RuntimeDiagnostics {

    static let historyLimit = 256

    private var history: [String] = []
    private var network: [String: String]?
    private var catalog: AppModel.AudioCatalog?
    private var selection: (input: String?, output: String?)?
    private var timer: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private weak var model: AppModel?

    private struct DeviceChoice: Equatable {
        var input: String?
        var output: String?
    }

    func start(model: AppModel) {
        self.model = model
        network = Self.interfaces()
        catalog = model.audioCatalog
        selection = (model.settings.audio.inputDeviceUID, model.settings.audio.outputDeviceUID)

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkNetwork() }
        }

        model.$audioCatalog
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] next in self?.compare(catalog: next) }
            .store(in: &subscriptions)

        model.$settings
            .map { (settings: AppSettings) -> DeviceChoice in
                DeviceChoice(input: settings.audio.inputDeviceUID, output: settings.audio.outputDeviceUID)
            }
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] (choice: DeviceChoice) in self?.compare(input: choice.input, output: choice.output) }
            .store(in: &subscriptions)
    }

    /// История сеанса — для архива поддержки.
    var historyText: String {
        history.isEmpty
            ? "Изменения оборудования и сети за текущий сеанс не обнаружены.\n"
            : history.joined(separator: "\n") + "\n"
    }

    /// Звук и сеть прямо сейчас — для архива поддержки.
    var statusText: String {
        let audio = catalog ?? AppModel.AudioCatalog()
        let net = (network ?? [:]).sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value)" }
        return ([
            ISO8601DateFormatter().string(from: Date()),
            "Микрофоны: " + audio.inputs.map(Self.model).joined(separator: "; "),
            "Выходы: " + audio.outputs.map(Self.model).joined(separator: "; "),
            "Микрофон по умолчанию: \(audio.defaultInputName ?? "нет")",
            "Выход по умолчанию: \(audio.defaultOutputName ?? "нет")",
            "Выбран в EliteSIP: микрофон \(name(selection?.input, in: audio.inputs)), выход \(name(selection?.output, in: audio.outputs))",
            "Сеть:",
        ] + (net.isEmpty ? ["  нет данных"] : net)).joined(separator: "\n") + "\n"
    }

    // MARK: - Сеть

    private func checkNetwork() {
        guard let current = Self.interfaces() else { return }
        if let previous = network {
            for name in Set(previous.keys).union(current.keys).sorted() {
                let before = previous[name] ?? "нет интерфейса"
                let after = current[name] ?? "нет интерфейса"
                if before != after {
                    record("Сеть \(name): \(before) → \(after)", kind: .network)
                }
            }
        }
        network = current
    }

    /// Интерфейсы без петли и локальных IPv6 — и шлюз отдельной строкой.
    nonisolated static func interfaces() -> [String: String]? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var addresses: [String: [String]] = [:]
        var up: [String: Bool] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let name = String(cString: entry.ifa_name)
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_LOOPBACK == 0, let address = entry.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if family == AF_INET6, text.lowercased().hasPrefix("fe80") { continue }
            addresses[name, default: []].append(text)
            up[name] = (up[name] ?? false) || flags & IFF_UP != 0 && flags & IFF_RUNNING != 0
        }

        var result = addresses.mapValues { $0.sorted().joined(separator: ", ") }
        for (name, list) in result {
            result[name] = "\(up[name] == true ? "работает" : "выключен"), IP [\(list)]"
        }
        if let router = gateway() {
            result["шлюз"] = "\(router.interface ?? "—") → \(router.address)"
        }
        return result
    }

    private nonisolated static func gateway() -> (address: String, interface: String?)? {
        guard let store = SCDynamicStoreCreate(nil, "EliteSIP" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let router = value["Router"] as? String
        else { return nil }
        return (router, value["PrimaryInterface"] as? String)
    }

    // MARK: - Звук

    private func compare(catalog next: AppModel.AudioCatalog) {
        defer { catalog = next }
        guard let before = catalog else { return }
        report(before: before.inputs, after: next.inputs, label: "микрофон")
        report(before: before.outputs, after: next.outputs, label: "выход")
        if before.defaultInputName != next.defaultInputName {
            record("Звук, микрофон по умолчанию: \(before.defaultInputName ?? "нет") → \(next.defaultInputName ?? "нет")",
                   kind: .audio(warning: false))
        }
        if before.defaultOutputName != next.defaultOutputName {
            record("Звук, выход по умолчанию: \(before.defaultOutputName ?? "нет") → \(next.defaultOutputName ?? "нет")",
                   kind: .audio(warning: false))
        }
    }

    private func report(before: [AudioDevice], after: [AudioDevice], label: String) {
        let old = Dictionary(before.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        let new = Dictionary(after.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        for device in before where new[device.uid] == nil {
            record("Звук, \(label) исчез: \(Self.model(device))", kind: .audio(warning: true))
        }
        for device in after where old[device.uid] == nil {
            record("Звук, \(label) появился: \(Self.model(device))", kind: .audio(warning: false))
        }
    }

    private func compare(input: String?, output: String?) {
        defer { selection = (input, output) }
        guard let previous = selection else { return }
        let audio = catalog ?? AppModel.AudioCatalog()
        if previous.input != input {
            record("Звук, микрофон выбран в EliteSIP: \(name(previous.input, in: audio.inputs)) → \(name(input, in: audio.inputs))",
                   kind: .audio(warning: false))
        }
        if previous.output != output {
            record("Звук, выход выбран в EliteSIP: \(name(previous.output, in: audio.outputs)) → \(name(output, in: audio.outputs))",
                   kind: .audio(warning: false))
        }
    }

    private func name(_ uid: String?, in devices: [AudioDevice]) -> String {
        guard let uid else { return "системный по умолчанию" }
        return devices.first { $0.uid == uid }.map(Self.model) ?? "отключённое устройство"
    }

    private nonisolated static func model(_ device: AudioDevice) -> String {
        "\(device.name) (\(device.transport))"
    }

    // MARK: - Запись

    private enum Kind { case network, audio(warning: Bool) }

    private func record(_ message: String, kind: Kind) {
        let text = LogRedaction.redact(message.replacingOccurrences(of: "\n", with: " "))
        history.append("\(ISO8601DateFormatter().string(from: Date())) \(text)")
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        // не переводится: строка журнала
        model?.append(level: .info, message: text)
        switch kind {
        case .network: ClientEventLog.shared.noteConnection(text)
        case .audio(let warning): ClientEventLog.shared.noteAudio(text, warning: warning)
        }
    }
}
