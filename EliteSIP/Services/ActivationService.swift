import Foundation
import PanelLink

/// Забрать пакет активации по ключу (M9, работа 2).
///
/// Единственный запрос, который приложение делает при активации, — и идёт он
/// **не в панель**, а на тот же канал раздачи, что и обновления. Панель стоит
/// на локальном сервере конторы и наружу не смотрит; сотрудник из дома до неё
/// не достаёт и достать не должен.
///
/// Адрес пакета выводится из самого ключа, поэтому сервера посередине не нужно:
/// его считают обе стороны одинаково. Знание адреса при этом ничего не даёт —
/// пакет по нему лежит зашифрованный тем же ключом.
///
/// **Ключ нигде не сохраняется.** Он одноразовый, и второй раз пакет не отдадут:
/// Worker перед бакетом столбит его за первым забравшим.
enum ActivationService {

    /// Забирает и распечатывает пакет.
    ///
    /// Ошибки не различают неверный ключ и испорченный файл — так решено в
    /// `PanelLink`: подбирающему незачем знать, где он ошибся.
    static func fetch(key: ActivationKey, installationID: String? = nil) async throws -> ActivationPackage {
        // Одна прогонка PBKDF2 на адрес и на ключ шифрования разом. Считается
        // до запроса: сто пятьдесят тысяч итераций — это около секунды на
        // Catalina, и делать её дважды незачем.
        let bound = try BoundActivationKey(key: key, installationID: installationID)

        guard let channel = Provisioning.secrets?.updates,
              let base = URL(string: channel.baseURL)
        else {
            throw PanelLinkError.keyDidNotOpen
        }

        // Приставка принадлежит раскладке бакета, а не расчёту адреса: ключ даёт
        // только шестнадцатеричное имя.
        let url = base
            .appendingPathComponent("activations")
            .appendingPathComponent(bound.objectName)

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let pair = "\(channel.user):\(channel.password)"
        if let encoded = pair.data(using: .utf8)?.base64EncodedString() {
            request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ActivationFailure.noChannel(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // 404 и 410 сводятся к одному ответу намеренно: «пакета нет» и
            // «пакет уже забрали» человеку означают одно и то же — нужен новый
            // ключ, — а различать их вслух значит подсказывать подбирающему,
            // какие адреса существуют.
            throw PanelLinkError.keyDidNotOpen
        }

        return try ActivationPackage.open(sealed: data, with: bound)
    }

    /// Отказ, который не про ключ, а про связь.
    ///
    /// Отдельно от `PanelLinkError`, потому что разбирается иначе: «нет сети» —
    /// это «попробуйте ещё раз», а «ключ не подошёл» — «попросите новый».
    /// Свести их в один текст значило бы отправить человека за новым ключом
    /// из-за отключённого Wi-Fi.
    enum ActivationFailure: Error, LocalizedError {
        case noChannel(String)

        var errorDescription: String? {
            switch self {
            case .noChannel(let reason):
                return String(
                    format: NSLocalizedString(
                        "Не удалось связаться с сервером: %@. Проверьте сеть и попробуйте снова.",
                        comment: "отказ при получении пакета активации"
                    ), reason)
            }
        }
    }
}
