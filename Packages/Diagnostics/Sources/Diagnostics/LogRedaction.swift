import Foundation

// не переводится: замена секрета в самом журнале.

/// Маскирование секретов перед записью в файл.
///
/// Журнал на рабочем месте существует затем, чтобы его прислали в поддержку.
/// Значит всё, что в него попало, рано или поздно уедет через мессенджер, ляжет
/// в чужие «Загрузки» и попадёт в бэкап. Файл, который нельзя приложить к
/// обращению, бесполезен ровно так же, как отсутствующий, — поэтому секреты
/// вырезаются на записи, а не при отправке.
///
/// Маскируются поля, а не заголовки целиком. `Authorization` без `response`
/// остаётся полезным: по `realm`, `nonce` и `algorithm` видно, чем именно
/// сервер недоволен, а вот `response` — это и есть ответ на вызов, то есть
/// производная пароля. Вырезать заголовок целиком значило бы сделать журнал
/// бесполезным ради того, что и так закрыто точечно.
public enum LogRedaction {

    /// Чем заменяется значение. Не пустая строка: по ней в журнале видно, что
    /// значение было и его убрали, а не что поле пришло пустым.
    public static let placeholder = "скрыто"

    /// Поля, значения которых не должны попадать в файл.
    ///
    /// Границы слова слева намеренно нет. `x-response=` или `authresponse=`
    /// тоже будут замаскированы, и это правильный перекос: лишняя маска стоит
    /// строки в журнале, пропущенная — пароля.
    static let secretFields = [
        "response",
        "password",
        "passwd",
        "pwd",
        "secret",
        "token",
        "apikey",
        "api_key",
    ]

    /// Ключевой материал SRTP из SDP: `a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:<ключ>|...`.
    ///
    /// Отдельным правилом, потому что отделяется двоеточием, а не знаком
    /// равенства. Это буквально ключ, которым шифруется разговор: в журнале ему
    /// не место ни в каком виде.
    static let inlineMarker = "inline:"

    /// Убирает значения секретных полей из строки.
    public static func redact(_ text: String) -> String {
        // Быстрый выход: в подавляющем большинстве строк искать нечего, а
        // журнал пишется на каждое событие сигнализации.
        guard containsCandidate(text) else { return text }

        let characters = Array(text)
        var result = ""
        result.reserveCapacity(characters.count)

        var index = 0
        while index < characters.count {
            if let match = matchSecretField(characters, at: index) {
                result.append(contentsOf: characters[index..<match.valueStart])
                result.append(placeholder)
                index = match.valueEnd
                continue
            }
            if let end = matchInline(characters, at: index) {
                result.append(inlineMarker)
                result.append(placeholder)
                index = end
                continue
            }
            result.append(characters[index])
            index += 1
        }
        return result
    }

    private static func containsCandidate(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains(inlineMarker) { return true }
        return secretFields.contains { lowered.contains($0) }
    }

    /// Если с позиции начинается `<поле> = <значение>`, возвращает границы
    /// значения: откуда его вырезать и где продолжить разбор.
    private static func matchSecretField(
        _ characters: [Character],
        at index: Int
    ) -> (valueStart: Int, valueEnd: Int)? {
        guard let field = secretFields.first(where: { matches($0, in: characters, at: index) }) else {
            return nil
        }

        var cursor = index + field.count
        cursor = skipWhitespace(characters, from: cursor)
        guard cursor < characters.count, characters[cursor] == "=" else { return nil }
        cursor += 1
        cursor = skipWhitespace(characters, from: cursor)
        guard cursor < characters.count else { return nil }

        // Значение в кавычках отдаётся вместе с ними: кавычки остаются в
        // журнале, чтобы строка не перестала быть похожей на заголовок.
        if characters[cursor] == "\"" {
            var end = cursor + 1
            while end < characters.count, characters[end] != "\"" { end += 1 }
            return (cursor + 1, min(end, characters.count))
        }

        var end = cursor
        while end < characters.count, !isValueTerminator(characters[end]) { end += 1 }
        guard end > cursor else { return nil }
        return (cursor, end)
    }

    /// Если с позиции начинается `inline:`, возвращает конец ключевого
    /// материала. Маскируется весь токен, включая срок жизни и индекс: разбирать
    /// их в журнале незачем, а ошибиться границей — значит оставить часть ключа.
    private static func matchInline(_ characters: [Character], at index: Int) -> Int? {
        guard matches(inlineMarker, in: characters, at: index) else { return nil }
        var end = index + inlineMarker.count
        while end < characters.count, !characters[end].isWhitespace { end += 1 }
        guard end > index + inlineMarker.count else { return nil }
        return end
    }

    private static func matches(_ needle: String, in characters: [Character], at index: Int) -> Bool {
        let needleCharacters = Array(needle)
        guard index + needleCharacters.count <= characters.count else { return false }
        for offset in 0..<needleCharacters.count {
            guard characters[index + offset].lowercased() == needleCharacters[offset].lowercased() else {
                return false
            }
        }
        return true
    }

    private static func skipWhitespace(_ characters: [Character], from index: Int) -> Int {
        var cursor = index
        while cursor < characters.count, characters[cursor] == " " || characters[cursor] == "\t" {
            cursor += 1
        }
        return cursor
    }

    /// Где кончается значение без кавычек.
    ///
    /// Запятая и точка с запятой разделяют параметры в заголовках SIP, скобка
    /// закрывает вставку в нашем собственном тексте, пробел кончает токен.
    private static func isValueTerminator(_ character: Character) -> Bool {
        character.isWhitespace
            || character == ","
            || character == ";"
            || character == ")"
            || character == "\""
    }
}
