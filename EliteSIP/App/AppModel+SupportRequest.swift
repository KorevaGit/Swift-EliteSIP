import Foundation
import PanelLink

/// Архив для техподдержки по просьбе Spark.
///
/// Тот же архив, что «Собрать архив для поддержки», только молча: человеку за
/// машиной не показывается ничего — архив нужен техподдержке, а не ему, и окно
/// посреди смены сбивало бы с разговора. След остаётся в журнале машины,
/// который видит Spark. Так же устроено в Windows- и Linux-версиях.
extension AppModel {

    /// Больше сервер обновлений не примет (`maxSupportArchive`).
    static let maxSupportArchive = 32 << 20

    /// Собрать архив и отправить `POST support/<request_id>`.
    ///
    /// Архив собирается в каталоге настроек, а не во временном: там он закрыт
    /// правами пользователя, и удаляется сразу после отправки. Не ушёл —
    /// следующий такт попробует снова, пока запрос не истёк.
    func sendSupportArchive(_ request: SupportRequest) async {
        let panel = settings.panel
        guard !isSendingSupportArchive, request.requestID != panel.sentSupportRequest else { return }
        let short = String(request.requestID.prefix(8))
        guard request.expiresAt > Date() else {
            append(level: .info, message: "запрос архива \(short) истёк — не отправляется")
            return
        }
        // Адрес отправки — `support/<request_id>`, а не `support/<машина>`:
        // сервер принимает архив только на запрос, что лежит сейчас.
        guard let url = Provisioning.secrets?.updates?.machineURL(prefix: "support", installationID: request.requestID)
        else { return }

        isSendingSupportArchive = true
        let path = SettingsStore.fileURL.deletingLastPathComponent()
            .appendingPathComponent("support-\(request.requestID).zip")
        defer {
            isSendingSupportArchive = false
            try? FileManager.default.removeItem(at: path)
        }

        do {
            append(level: .info, message: "Spark просит архив для техподдержки (\(short)) — собираем")
            _ = try await makeSupportArchive(to: path)
            let data = try Data(contentsOf: path)
            guard data.count <= Self.maxSupportArchive else {
                // Повтор дал бы тот же размер: запрос считается отвеченным.
                markSupportAnswered(request)
                ClientEventLog.shared.record(.error, .warning,
                    "Архив для техподдержки не отправлен: \(data.count >> 20) МБ, больше предела 32 МБ")
                return
            }

            var upload = MachineService.machineRequest(url: url, panel: panel)
            upload.httpMethod = "POST"
            upload.timeoutInterval = 5 * 60
            upload.setValue("application/zip", forHTTPHeaderField: "Content-Type")
            let status = try await Self.post(upload, body: data)
            switch status {
            case 200, 204:
                markSupportAnswered(request)
                append(level: .info, message: "архив для техподдержки отправлен: \(data.count / 1024) КБ")
                ClientEventLog.shared.record(.config, .info,
                    "Архив для техподдержки отправлен по запросу Spark (\(max(1, data.count / 1024)) КБ)")
            case 404:
                // Запрос уже снят: истёк в Spark или машину отвязали.
                markSupportAnswered(request)
                append(level: .info, message: "архив для техподдержки: запрос на сервере уже снят")
            default:
                append(level: .warning,
                       message: "архив для техподдержки: сервер ответил \(status), повтор следующим тактом")
            }
        } catch {
            append(level: .warning,
                   message: "архив для техподдержки не отправлен: \(error.localizedDescription); повтор следующим тактом")
        }
    }

    /// Отправка с обработчиком, а не `upload(for:from:)`: тот только с macOS 12.
    private static func post(_ request: URLRequest, body: Data) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.uploadTask(with: request, from: body) { _, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (response as? HTTPURLResponse)?.statusCode ?? 0)
                }
            }.resume()
        }
    }

    private func markSupportAnswered(_ request: SupportRequest) {
        settings.panel.sentSupportRequest = request.requestID
        persistSettings()
    }
}
