import Foundation
import Security

/// Пароль от SIP хранится только здесь.
///
/// Не в файле настроек, не в UserDefaults и не в модели: файл настроек уезжает в
/// синхронизацию с EliteDash и в выгрузку диагностики, а Keychain — нет.
enum KeychainStore {

    static let service = "com.elite.EliteSIP.sip-password"

    enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "код \(status)"
                return "Keychain: \(message)"
            }
        }
    }

    /// Ключ записи — «номер@домен»: у одного человека может быть учётка и в
    /// лаборатории, и в бою, и путать их пароли нельзя.
    static func key(for account: String, domain: String) -> String {
        "\(account)@\(domain)"
    }

    static func save(password: String, for key: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        // Пустой пароль трактуем как «удалить»: хранить пустую строку смысла нет,
        // а её наличие сбивает признак «пароль задан».
        guard !password.isEmpty else {
            try delete(for: key)
            return
        }

        let data = Data(password.utf8)
        let status = SecItemCopyMatching(query as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }

        case errSecItemNotFound:
            query[kSecValueData as String] = data
            // Доступ только когда устройство разблокировано, и без синхронизации
            // в iCloud: пароль от офисной АТС там не нужен.
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }

        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Есть ли сохранённый пароль — без чтения самого пароля.
    ///
    /// Разница принципиальная, и стоила она зависшего запуска. ACL связки ключей
    /// защищает **данные** записи: за ними macOS спрашивает разрешение, если
    /// подпись приложения изменилась, и `SecItemCopyMatching` блокирует поток до
    /// ответа человека. Запрос без `kSecReturnData` ничего не расшифровывает,
    /// поэтому не спрашивает и не блокирует — а на вопрос «пароль задан?»
    /// отвечает столь же точно.
    ///
    /// Подпись меняется при каждой пересборке с `CODE_SIGN_IDENTITY = "-"`,
    /// то есть в разработке — на каждой. Постоянная подпись появится в M7
    /// вместе с нотаризацией, но полагаться на неё здесь нельзя: у оператора
    /// запись в связке ключей может оказаться созданной другой сборкой.
    static func hasPassword(for key: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Пароль целиком.
    ///
    /// Здесь диалог разрешения возможен, и это нормально: вызывать эту функцию
    /// можно только в ответ на действие человека и только не с главного потока
    /// — иначе интерфейс замирает ровно в тот момент, когда от человека ждут
    /// ответа. См. `AppModel.loadStoredPassword`.
    static func password(for key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func delete(for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
