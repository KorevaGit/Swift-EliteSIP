import CryptoKit
import Foundation

/// Всё, что рабочее место помнит про административный пароль.
///
/// Одно значение: `loginHash` — проверочное. По нему проверяется вход, и
/// восстановить из него пароль нельзя. Файл настроек уезжает в бэкапы, и
/// пароля в нём быть не должно.
///
/// **Кода восстановления здесь больше нет** (25 августа 2026). Он держал рядом
/// с хешем тот же пароль, зашифрованный шестизначным кодом, и код этот лежал
/// открытым текстом в бандле каждого приложения — то есть «восстановление»
/// работало у всякого, кто вскрыл `.app`. Держался он на продуктовом решении
/// «код показывает актуальный пароль»; теперь актуальный пароль показывает
/// панель, потому что оттуда он и приезжает. Забывший его администратор
/// смотрит в панель, а не расшифровывает файл на машине.
public struct AdminCredential: Codable, Sendable, Equatable {

    /// Итераций PBKDF2 для новых учётных данных. Подробности выбора — в
    /// `KeyDerivation`.
    public static let defaultIterations = KeyDerivation.defaultIterations

    /// Итераций PBKDF2. Хранится, а не берётся из константы: поднять цену
    /// перебора на новых установках нужно, не сломав старые.
    public var iterations: Int

    /// Соль проверочного значения.
    public var loginSalt: Data

    /// PBKDF2 от пароля. Сам пароль отсюда не достаётся.
    public var loginHash: Data

    public init(iterations: Int, loginSalt: Data, loginHash: Data) {
        self.iterations = iterations
        self.loginSalt = loginSalt
        self.loginHash = loginHash
    }

    /// Новые учётные данные для пароля.
    public init(
        password: String,
        iterations: Int = AdminCredential.defaultIterations
    ) throws {
        guard !password.isEmpty else { throw AdminAccessError.emptyPassword }

        let loginSalt = KeyDerivation.randomSalt()
        let loginHash = try KeyDerivation.derive(from: password, salt: loginSalt, iterations: iterations)

        self.init(iterations: iterations, loginSalt: loginSalt, loginHash: loginHash)
    }

    /// Тот ли это пароль.
    ///
    /// Ошибку деривации проглатываем в `false`: для вызывающего «не удалось
    /// проверить» и «не подошёл» — одно и то же закрытое окно, а два разных
    /// сообщения на одном экране только подсказывали бы подбирающему.
    public func matches(password: String) -> Bool {
        guard !password.isEmpty, !loginSalt.isEmpty, !loginHash.isEmpty else { return false }
        guard
            let candidate = try? KeyDerivation.derive(
                from: password,
                salt: loginSalt,
                // Число из файла — см. `KeyDerivation.boundedIterations`. Без
                // границ одна правка в JSON вешает вход намертво, и выглядит
                // это как зависшее приложение, а не как испорченный файл.
                iterations: KeyDerivation.boundedIterations(iterations),
                byteCount: loginHash.count
            )
        else { return false }
        return KeyDerivation.constantTimeEquals(candidate, loginHash)
    }
}
