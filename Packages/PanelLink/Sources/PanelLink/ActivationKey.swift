import CommonCrypto
import Foundation

/// Ключ активации — то, что сотрудник вводит в мастере.
///
/// Ключ делает три вещи сразу, и это решение панели, а не наше удобство:
/// называет пакет в канале раздачи, отпирает его и опознаёт активацию в панели.
/// Отсюда главное следствие для приложения: **ключ нигде не сохраняется.** Он
/// одноразовый, и второй раз пакет не отдадут.
///
/// Формат и выводы адресов — elitesip-site/docs/CONTRACT.md.
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

    /// Имя пакета в канале раздачи — та самая шестнадцатеричная строка.
    ///
    /// Считается из ключа односторонне, поэтому его знают обе стороны, а сервер
    /// посередине не нужен. Знание адреса при этом ничего не даёт: пакет по
    /// нему лежит зашифрованный тем же ключом.
    ///
    /// Приставка `activations/` сюда не входит: она принадлежит раскладке
    /// бакета и приезжает внутри адреса канала.
    public var objectName: String {
        Self.hex(Self.sha256(Data("elitesip.activation.object.v1\0\(canonical)".utf8)).prefix(16))
    }

    /// Соль для вывода ключа шифрования.
    ///
    /// Выводится из ключа, а не берётся случайной. Обычно так нельзя; здесь
    /// можно, потому что ключ случаен и живёт двое суток — повторов, ради
    /// которых соль и случайна, не бывает. Зато машине не нужно знать ничего,
    /// кроме ключа: ни соли рядом с шифротекстом, ни параметров в заголовке.
    var salt: Data {
        Data(Self.sha256(Data("elitesip.activation.salt.v1\0\(canonical)".utf8)).prefix(16))
    }

    /// Показать так, как показывает панель: группами по четыре.
    public var grouped: String {
        stride(from: 0, to: canonical.count, by: 4).map { offset in
            let start = canonical.index(canonical.startIndex, offsetBy: offset)
            let end = canonical.index(start, offsetBy: 4, limitedBy: canonical.endIndex) ?? canonical.endIndex
            return String(canonical[start..<end])
        }.joined(separator: "-")
    }

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
