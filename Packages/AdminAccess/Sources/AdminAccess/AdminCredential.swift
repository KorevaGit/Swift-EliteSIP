import CryptoKit
import Foundation

/// Всё, что рабочее место помнит про административный пароль.
///
/// Два независимых значения, и это главное решение подэтапа:
///
/// 1. `loginHash` — проверочное значение. По нему проверяется ежедневный вход,
///    и восстановить из него пароль нельзя. Ровно то, чего требовал роадмап:
///    файл настроек уезжает в бэкапы, и пароля в нём быть не должно.
/// 2. `recoveryBox` — тот же пароль, зашифрованный ключом из кода
///    восстановления. Это уступка продуктовому решению «код показывает
///    актуальный пароль», и уступка осознанная: пароль синхронизирован с
///    EliteDash, поэтому сбросить его локально — значит развести машину с
///    системой, а не починить её.
///
/// Утёкший файл сам по себе пароля не выдаёт: без кода восстановления
/// `recoveryBox` — это шум. Цена честно записана в `RecoveryCode`.
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

    /// Соль ключа, которым запечатан пароль.
    public var recoverySalt: Data

    /// AES-GCM в «combined»-виде: nonce, шифротекст и тег одной строкой.
    /// Подмена любого байта ломает тег, то есть правка файла руками не даёт
    /// подсунуть свой пароль — она даёт отказ.
    public var recoveryBox: Data

    public init(
        iterations: Int,
        loginSalt: Data,
        loginHash: Data,
        recoverySalt: Data,
        recoveryBox: Data
    ) {
        self.iterations = iterations
        self.loginSalt = loginSalt
        self.loginHash = loginHash
        self.recoverySalt = recoverySalt
        self.recoveryBox = recoveryBox
    }

    /// Новые учётные данные для пароля и кода восстановления.
    public init(
        password: String,
        recoveryCode: String = RecoveryCode.provisioned,
        iterations: Int = AdminCredential.defaultIterations
    ) throws {
        guard !password.isEmpty else { throw AdminAccessError.emptyPassword }
        let code = RecoveryCode.normalized(recoveryCode)
        guard RecoveryCode.isWellFormed(code) else { throw AdminAccessError.malformedRecoveryCode }

        let loginSalt = KeyDerivation.randomSalt()
        let recoverySalt = KeyDerivation.randomSalt()
        let loginHash = try KeyDerivation.derive(from: password, salt: loginSalt, iterations: iterations)
        let sealingKey = try KeyDerivation.derive(from: code, salt: recoverySalt, iterations: iterations)

        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(Data(password.utf8), using: SymmetricKey(data: sealingKey))
        } catch {
            throw AdminAccessError.derivationFailed
        }
        guard let combined = sealed.combined else { throw AdminAccessError.derivationFailed }

        self.init(
            iterations: iterations,
            loginSalt: loginSalt,
            loginHash: loginHash,
            recoverySalt: recoverySalt,
            recoveryBox: combined
        )
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
                from: password, salt: loginSalt, iterations: iterations, byteCount: loginHash.count
            )
        else { return false }
        return KeyDerivation.constantTimeEquals(candidate, loginHash)
    }

    /// Пароль, восстановленный по коду.
    ///
    /// Возвращается именно исходная строка, а не новая: её и показывают
    /// администратору, чтобы он узнал пароль, а не завёл второй.
    public func password(recoveryCode: String) throws -> String {
        let code = RecoveryCode.normalized(recoveryCode)
        guard RecoveryCode.isWellFormed(code) else { throw AdminAccessError.malformedRecoveryCode }
        guard !recoverySalt.isEmpty, !recoveryBox.isEmpty else {
            throw AdminAccessError.malformedCredential
        }

        let key = try KeyDerivation.derive(from: code, salt: recoverySalt, iterations: iterations)
        guard
            let sealed = try? AES.GCM.SealedBox(combined: recoveryBox),
            let opened = try? AES.GCM.open(sealed, using: SymmetricKey(data: key)),
            let password = String(data: opened, encoding: .utf8)
        else {
            // Неверный код и испорченный ящик неотличимы по тегу GCM, и это
            // правильно: подбирающему незачем знать, что он ошибся кодом, а не
            // наткнулся на битый файл.
            throw AdminAccessError.wrongRecoveryCode
        }
        return password
    }
}
