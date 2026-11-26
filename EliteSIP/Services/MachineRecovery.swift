import CryptoKit
import Foundation
import PanelLink
import SIPCore

/// Заявка на восстановление машины в Spark — перенос `MachineRecovery` из
/// Windows-клиента (0.1.71 на macOS, утерянной вместе с исходниками).
///
/// **Зачем.** База Spark потеряна: машины, привязанные до потери, Spark больше
/// не знает. Каждая такая машина сама присылает то, что у неё есть, — номер,
/// подпись, предустановку, формат работы, управляемые поля и открытый ключ, —
/// а администратор принимает заявку в Spark, и привязка восстанавливается без
/// нового ключа.
///
/// **Доказательство.** Пароль SIP не покидает машину: к заявке прикладывается
/// HMAC-SHA256 от `elitesip-recovery-v1\n` + тело заявки на пароле каждого
/// номера. Spark сверяет его с АТС-паролем, который знает администратор.
///
/// **Когда.** Окно восстановления открывает Spark (`GET` отвечает 204), заявка
/// уходит один раз на окно: принятая (202) запоминается на сутки
/// (`receiptLifetime`), как в Windows 1.0.5. Работает и в ручном
/// режиме — по сохранённым данным привязки, как в Windows.
///
/// Механика временная, на один выпуск: после восстановления базы её убрать.
@MainActor
final class MachineRecovery {

    private static let prefix = Data("elitesip-recovery-v1\n".utf8)

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    private var sending = false

    /// Сколько помнить принятую заявку. Spark отвечает 202 и машине, которую
    /// ещё знает, не заводя заявки; без срока такая квитанция навсегда
    /// закрывала бы отправку в следующее окно восстановления. Сутки — длина окна.
    static let receiptLifetime: TimeInterval = 24 * 60 * 60

    static func hasFreshReceipt(_ panel: AppSettings.PanelSettings, now: Date = Date()) -> Bool {
        guard panel.recoverySubmittedInstallationID == panel.installationID,
              let at = panel.recoverySubmittedAt else { return false }
        return now.timeIntervalSince(at) < receiptLifetime
    }

    func check(model: AppModel) async {
        let settings = model.settings
        let panel = settings.panel
        guard !sending, panel.hasChannelKey, panel.appliedRevision >= 1,
              !Self.hasFreshReceipt(panel)
        else { return }

        let endpoint = PairService.baseURL.appendingPathComponent("api/pair/recovery")
        guard endpoint.scheme == "https" else { return }

        let installationID = panel.installationID
        sending = true
        defer { sending = false }

        do {
            var probe = URLRequest(url: endpoint)
            probe.httpMethod = "GET"
            let (_, window) = try await Self.session.data(for: probe)
            guard (window as? HTTPURLResponse)?.statusCode == 204,
                  model.settings.panel.installationID == installationID
            else { return }

            guard let body = Self.request(settings: model.settings) else {
                // не переводится: строка журнала
                model.append(level: .warning,
                             message: "восстановление Spark: заявка не собрана — нет ключа машины, предустановки или пароля номера")
                return
            }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let (_, response) = try await Self.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 202, model.settings.panel.installationID == installationID {
                model.settings.panel.recoverySubmittedInstallationID = installationID
                model.settings.panel.recoverySubmittedAt = Date()
                model.persistSettings()
                // не переводится: строка журнала
                model.append(level: .info, message: "восстановление Spark: заявка принята")
            } else {
                // не переводится: строка журнала
                model.append(level: .warning, message: "восстановление Spark: заявка отклонена (\(status))")
            }
        } catch {
            // не переводится: строка журнала
            model.append(level: .info,
                         message: "восстановление Spark: заявку не удалось отправить (\(error.localizedDescription))")
        }
    }

    /// Тело запроса: `{"payload": base64(JSON), "proofs": {номер: HMAC}}` —
    /// ровно как сериализует его Windows (`byte[]` в System.Text.Json — base64).
    /// `nil` — заявку собрать нечем: нет ключа, предустановки или пароля.
    static func request(settings: AppSettings) -> Data? {
        let panel = settings.panel
        guard let raw = Data(base64Encoded: panel.machineKey),
              let keyPair = try? MachineKeyPair(rawPrivateKey: raw),
              !panel.channelKey.isEmpty, !panel.presetName.isEmpty
        else { return nil }

        let profiles = settings.profiles.profiles
        guard let main = profiles.first else { return nil }
        let extra = profiles.dropFirst().sorted { $0.account.username < $1.account.username }

        let payload: [String: Any] = [
            "installation_id": panel.installationID,
            "channel_key_hash": ChannelKey.hash(panel.channelKey),
            "public_key": keyPair.publicKeyBase64,
            "device_name": PairService.deviceName,
            "extension": main.account.username,
            "label": main.label,
            "work_format": main.site == .remote ? "remote" : "office",
            "work_format_locked": panel.isWorkFormatLocked,
            "preset_id": panel.presetID,
            "preset_name": panel.presetName,
            "preset_revision": panel.appliedRevision,
            "config_revision": panel.appliedConfigRevision,
            "fields": presetFields(settings),
            "lines": extra.map { ["extension": $0.account.username, "label": $0.label] },
        ]
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }

        let message = prefix + payloadData
        var proofs: [String: String] = [:]
        for profile in profiles {
            let number = profile.account.username
            guard !profile.password.isEmpty, !number.isEmpty, proofs[number] == nil else { return nil }
            let code = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(profile.password.utf8)))
            proofs[number] = code.map { String(format: "%02X", $0) }.joined()
        }

        return try? JSONSerialization.data(withJSONObject: [
            "payload": payloadData.base64EncodedString(),
            "proofs": proofs,
        ])
    }

    /// Управляемые поля — те же ключи, что приезжают в предустановке
    /// (`ManagedFields`), чтобы Spark мог восстановить её содержимое.
    private static func presetFields(_ settings: AppSettings) -> [String: Any] {
        let guardPolicy = settings.incomingCall
        let dtmf = settings.dtmf
        return [
            "dtmf": [
                "toneMilliseconds": dtmf.toneMilliseconds,
                "gapMilliseconds": dtmf.gapMilliseconds,
                "pauseMilliseconds": dtmf.pauseMilliseconds,
                "macros": dtmf.macros.map { [
                    "id": $0.id.uuidString,
                    "title": $0.title,
                    "sequence": $0.sequence,
                    "transfersCall": $0.transfersCall,
                ] },
                "macroColumns": dtmf.macroColumns,
                "macroHeight": dtmf.macroHeight,
                "macroHeightIsManual": dtmf.macroHeightIsManual,
            ] as [String: Any],
            "incomingCall": [
                "isEnabled": guardPolicy.isEnabled,
                "isRandomPositionEnabled": guardPolicy.isRandomPositionEnabled,
                "tunesRandomnessByHand": guardPolicy.tunesRandomnessByHand,
                "minimumTravel": guardPolicy.minimumTravel,
                "screenMargin": guardPolicy.screenMargin,
                "targetCount": guardPolicy.targetCount,
                "requiresCursorMovement": guardPolicy.requiresCursorMovement,
                "tunesLivenessByHand": guardPolicy.tunesLivenessByHand,
                "requiredCursorTravel": guardPolicy.requiredCursorTravel,
                "requiredCursorSamples": guardPolicy.requiredCursorSamples,
                "rejectsSyntheticEvents": guardPolicy.rejectsSyntheticEvents,
            ] as [String: Any],
            "conference": [
                "featureCode": settings.conference.featureCode,
                "roomExtension": settings.conference.roomExtension,
            ],
            "siteAddresses": [
                "office": settings.siteAddresses.office,
                "remote": settings.siteAddresses.remote,
            ],
            "portKnock": [
                "spacingSeconds": settings.portKnock.spacingSeconds,
                "repeatIntervalSeconds": settings.portKnock.repeatIntervalSeconds,
                "steps": settings.portKnock.steps.map { [
                    "host": $0.host,
                    "payloadBytes": $0.payloadBytes,
                    "count": $0.count,
                ] as [String: Any] },
            ] as [String: Any],
            "acceptsAnyTLSCertificate": settings.acceptsAnyTLSCertificate,
            "transport": settings.profiles.active.account.transport == .tls ? "tls" : "udp",
            "autoAnswer": settings.autoAnswer.rawValue,
            "autoAnswerNumbers": settings.autoAnswerNumbers.map(\.number),
            "masksMobileNumbers": settings.masksMobileNumbers,
        ]
    }
}
