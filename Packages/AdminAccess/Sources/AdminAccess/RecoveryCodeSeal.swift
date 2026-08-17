import CryptoKit
import Foundation

/// Данные, запечатанные кодом восстановления.
///
/// Тот же примитив, что `recoveryBox` у `AdminCredential`, но для произвольного
/// содержимого: приложение запечатывает им файл конфигурации рабочего места.
/// Лежит здесь, а не в приложении, по причине, ради которой пакет и заведён, —
/// криптографию нельзя принимать глазами, и проверять её надо тестом. У
/// приложения тестов нет вовсе.
///
/// **Ключом служит код восстановления, и это решение, а не удобство.** Файл
/// конфигурации существует ради переноса рабочего места на новый компьютер:
/// снятый на одной машине, он обязан открыться на другой. Ключ, привязанный к
/// машине, сделал бы перенос невозможным ровно в том случае, для которого файл
/// и придуман. Код же одинаков у всех установок и меняется провижинингом.
///
/// **Чего это не даёт.** Код лежит в бандле приложения открытым текстом, и от
/// того, кто вскроет `.app`, запечатывание не защищает никак. Оно защищает от
/// другого, и это «другое» — то, что случается на самом деле: пароль перестаёт
/// лежать читаемой строкой в файле, который уехал в мессенджер, в чужие
/// «Загрузки» и в чужой бэкап. Называть это защитой от злоумышленника нельзя;
/// называть бесполезным — тоже.
public struct RecoveryCodeSeal: Codable, Sendable, Equatable {

    /// Итераций PBKDF2. Хранится рядом с данными по той же причине, что и у
    /// `AdminCredential`: поднять цену перебора нужно, не сломав уже
    /// выпущенные файлы.
    public var iterations: Int

    /// Соль вывода ключа. Своя у каждого файла, поэтому два одинаковых слепка,
    /// запечатанных одним кодом, дают разные байты.
    public var salt: Data

    /// AES-GCM в «combined»-виде: nonce, шифротекст и тег одной строкой.
    /// Подмена любого байта ломает тег — правка файла руками даёт отказ, а не
    /// подсунутое содержимое.
    public var box: Data

    /// Итераций для новых файлов. Подробности выбора — в `KeyDerivation`.
    public static let defaultIterations = KeyDerivation.defaultIterations

    public init(iterations: Int, salt: Data, box: Data) {
        self.iterations = iterations
        self.salt = salt
        self.box = box
    }

    /// Запечатывает данные кодом.
    public static func seal(
        _ payload: Data,
        code: String,
        iterations: Int = RecoveryCodeSeal.defaultIterations
    ) throws -> RecoveryCodeSeal {
        let code = RecoveryCode.normalized(code)
        guard RecoveryCode.isWellFormed(code) else { throw AdminAccessError.malformedRecoveryCode }

        let salt = KeyDerivation.randomSalt()
        let key = try KeyDerivation.derive(from: code, salt: salt, iterations: iterations)

        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(payload, using: SymmetricKey(data: key))
        } catch {
            throw AdminAccessError.derivationFailed
        }
        guard let combined = sealed.combined else { throw AdminAccessError.derivationFailed }

        return RecoveryCodeSeal(iterations: iterations, salt: salt, box: combined)
    }

    /// Открывает запечатанное.
    ///
    /// Неверный код и испорченный файл неотличимы по ответу, и это правильно:
    /// подбирающему незачем знать, что он ошибся кодом, а не наткнулся на
    /// битые байты.
    public func open(code: String) throws -> Data {
        let code = RecoveryCode.normalized(code)
        guard RecoveryCode.isWellFormed(code) else { throw AdminAccessError.malformedRecoveryCode }
        guard !salt.isEmpty, !box.isEmpty else { throw AdminAccessError.malformedCredential }

        // Число итераций приезжает из файла, то есть снаружи, и брать его на
        // веру нельзя: см. `KeyDerivation.maximumIterations`. Потолок тот же,
        // что у учётных данных, — и по той же причине.
        let key = try KeyDerivation.derive(
            from: code,
            salt: salt,
            iterations: KeyDerivation.boundedIterations(iterations)
        )

        guard
            let sealed = try? AES.GCM.SealedBox(combined: box),
            let opened = try? AES.GCM.open(sealed, using: SymmetricKey(data: key))
        else {
            throw AdminAccessError.wrongRecoveryCode
        }
        return opened
    }
}
