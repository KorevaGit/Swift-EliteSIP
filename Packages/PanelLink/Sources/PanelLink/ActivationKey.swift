import CommonCrypto
import Foundation

/// Ключ активации — то, что сотрудник вводит в мастере.
///
/// Ключ делает три вещи сразу, и это решение панели, а не наше удобство:
/// называет пакет в канале раздачи, отпирает его и опознаёт активацию в панели.
/// Отсюда главное следствие для приложения: **ключ нигде не сохраняется.** Он
/// одноразовый, и второй раз пакет не отдадут.
///
/// Формат и выводы адресов — elitesupport/docs/CONTRACT.md.
public struct ActivationKey: Sendable, Equatable {

    /// Алфавит Crockford Base32.
    ///
    /// Из него убраны `I`, `L`, `O` и `U`: первые три путаются с единицей и
    /// нулём на слух и в шрифтах, последняя выпала, чтобы из ключа случайно не
    /// складывалось слов.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Длина ключа в знаках.
    public static let length = 12

    /// Канонический вид: двенадцать знаков алфавита, без разделителей.
    public let canonical: String

    /// Разбирает то, что ввёл человек.
    ///
    /// Разбор нарочно терпимый. Ключ диктуют по телефону и вставляют из
    /// мессенджера вместе с пробелами и переносами, поэтому:
    ///
    /// - регистр не важен;
    /// - выбрасывается всё, что не буква и не цифра;
    /// - `O` приводится к нулю, `I` и `L` — к единице.
    ///
    /// Последнее не любезность, а необходимость: этих букв в алфавите нет
    /// вовсе, и прочитавший ноль как «о» иначе получал бы отказ, не понимая
    /// почему.
    ///
    /// **Разделители не перечисляются списком, а определяются от обратного** —
    /// и это не лень. Первый заход перечислял их поимённо и споткнулся на
    /// `"\r\n"`: в Swift пара CR LF — это один `Character`, а не два, и она не
    /// совпадала ни с `"\r"`, ни с `"\n"`. Ключ, скопированный из мессенджера на
    /// Windows, отвергался бы как непохожий на ключ. Ошибку нашёл тест; списком
    /// её пришлось бы ловить ещё и на неразрывном пробеле, длинном тире и всём
    /// прочем, что вставляется вместе с текстом.
    ///
    /// С 25 августа 2026 это же правило действует и в панели: до него панель
    /// перечисляла разделители списком и была строже приложения — ключ, который
    /// приложение принимало, поиск по ключу отвергал как «не ключ».
    public init(input: String) throws {
        var digits: [Character] = []

        for character in input.uppercased() {
            guard character.isLetter || character.isNumber else { continue }

            switch character {
            case "O":
                digits.append("0")
            case "I", "L":
                digits.append("1")
            default:
                guard Self.alphabet.contains(character) else {
                    throw PanelLinkError.malformedKey
                }
                digits.append(character)
            }
        }

        guard digits.count == Self.length else {
            throw PanelLinkError.malformedKey
        }
        canonical = String(digits)
    }

    /// Показать так, как показывает панель: группами по четыре.
    public var grouped: String {
        stride(from: 0, to: canonical.count, by: 4).map { offset in
            let start = canonical.index(canonical.startIndex, offsetBy: offset)
            let end = canonical.index(start, offsetBy: 4, limitedBy: canonical.endIndex) ?? canonical.endIndex
            return String(canonical[start..<end])
        }.joined(separator: "-")
    }
}

/// Ключ вместе с выведенным из него материалом.
///
/// Тип существует затем, чтобы прогонка была ровно одна. Имя объекта и ключ
/// шифрования — разные куски одного вывода PBKDF2, и считать их по отдельности
/// значило бы заплатить второй секундой на Catalina, где человек и так ждёт у
/// экрана. Поэтому же это не вычисляемые свойства ключа: сто пятьдесят тысяч
/// итераций не должны прятаться за точкой.
public struct BoundActivationKey: Sendable {

    /// Число итераций PBKDF2.
    ///
    /// Взято у панели, а панель взяла его у `AdminAccess.KeyDerivation`. Argon2id
    /// здесь был бы уместнее, но его нет ни в CryptoKit, ни в CommonCrypto на
    /// Catalina, а тянуть ради него зависимость в однозависимое приложение
    /// нельзя — разбор в elitesupport/docs/DECISIONS.md.
    static let iterations = 150_000

    static let nameLength = 16
    static let keyLength = 32

    /// Имя пакета в канале раздачи — та самая шестнадцатеричная строка.
    ///
    /// Приставка `activations/` сюда не входит: она принадлежит раскладке
    /// бакета и приезжает внутри адреса канала.
    public let objectName: String

    /// Ключ AES-GCM. Наружу не отдаётся.
    let cipherKey: Data

    /// Считает материал ключа.
    ///
    /// ```
    /// соль  = SHA-256("elitesip.activation.salt.v2\0" + ключ + "\0" + машина)[:16]
    /// вывод = PBKDF2-HMAC-SHA256(ключ, соль, 150 000, 48)
    /// имя объекта = hex(вывод[0..16])
    /// ключ AES    = вывод[16..48]
    /// ```
    ///
    /// **Соль выводится из ключа, а не берётся случайной.** Обычно так нельзя;
    /// здесь можно, потому что ключ случаен и живёт двое суток — повторов, ради
    /// которых соль и случайна, не бывает. Зато машине не нужно знать ничего,
    /// кроме ключа: ни соли рядом с шифротекстом, ни параметров в заголовке.
    ///
    /// **Имя объекта растянуто вместе с ключом шифрования.** Раньше оно
    /// считалось голым SHA-256 от ключа — а в ключе шестьдесят бит, и утёкшая
    /// база панели давала готовый образ для перебора.
    ///
    /// - Parameter installationID: машина, к которой привязан ключ. `nil` у
    ///   ключа активации: машины ещё нет. У ключа перепрошивки — идентификатор
    ///   этой машины, и тогда чужой ключ считает другой адрес и не находит по
    ///   нему ничего. Проверять привязку внутри пакета было нельзя: Worker
    ///   столбит пакет в момент скачивания, и перепутавший свои же два
    ///   компьютера сжигал бы ключ до всякой проверки.
    public init(key: ActivationKey, installationID: String? = nil) throws {
        let binding = installationID ?? ""
        let salt = ActivationKey.sha256(
            Data("elitesip.activation.salt.v2\0\(key.canonical)\0\(binding)".utf8)
        ).prefix(16)

        let material = try Self.derive(password: key.canonical, salt: Data(salt),
                                       length: Self.nameLength + Self.keyLength)

        objectName = ActivationKey.hex(material.prefix(Self.nameLength))
        cipherKey = Data(material.suffix(Self.keyLength))
    }

    static func derive(password: String, salt: Data, length: Int) throws -> Data {
        let secretBytes = Array(password.utf8)
        var derived = Data(count: length)

        let status: Int32 = derived.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBuffer in
                secretBytes.withUnsafeBufferPointer { secretBuffer in
                    let pointer = secretBuffer.baseAddress.map {
                        UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self)
                    }
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pointer,
                        secretBytes.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        output.bindMemory(to: UInt8.self).baseAddress,
                        length
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw PanelLinkError.keyDidNotOpen }
        return derived
    }
}

extension ActivationKey {

    // MARK: - Мелочь

    static func sha256(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest)
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
