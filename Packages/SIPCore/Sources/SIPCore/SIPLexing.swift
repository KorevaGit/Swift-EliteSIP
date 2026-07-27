/// Мелкая лексика SIP, общая для URI, Via, name-addr и заголовков авторизации.
///
/// Ключевая мысль всего файла: наивный `split(separator:)` в SIP почти всегда
/// неверен. Запятая внутри `"display, name"` не разделяет значения, точка с
/// запятой внутри `<sip:a@b;transport=tls>` не начинает параметр заголовка, а в
/// `Digest realm="a", nonce="b"` запятая разделяет параметры одного значения, а
/// не два значения. Поэтому всё режется с учётом кавычек и угловых скобок.
enum SIPLexer {

    /// Режет строку по разделителю, игнорируя разделители внутри двойных
    /// кавычек и внутри `<...>`.
    static func splitTopLevel(
        _ text: Substring,
        separator: Character,
        omittingEmpty: Bool = true
    ) -> [Substring] {
        var result: [Substring] = []
        var start = text.startIndex
        var inQuotes = false
        var inAngles = false
        var escaped = false

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]

            if escaped {
                escaped = false
            } else if inQuotes {
                switch character {
                case "\\": escaped = true
                case "\"": inQuotes = false
                default: break
                }
            } else {
                switch character {
                case "\"": inQuotes = true
                case "<": inAngles = true
                case ">": inAngles = false
                case separator where !inAngles:
                    let piece = text[start..<index]
                    if !omittingEmpty || !piece.trimmedSIP.isEmpty {
                        result.append(piece)
                    }
                    start = text.index(after: index)
                default: break
                }
            }

            index = text.index(after: index)
        }

        let tail = text[start...]
        if !omittingEmpty || !tail.trimmedSIP.isEmpty {
            result.append(tail)
        }
        return result
    }

    /// Разбирает список параметров вида `;a=1;b="x;y";flag`.
    /// Ведущая точка с запятой не обязательна.
    static func parseParameters(_ text: Substring) -> [SIPURI.Parameter] {
        var body = text
        if body.first == ";" {
            body = body.dropFirst()
        }
        return splitTopLevel(body, separator: ";").compactMap { raw in
            let piece = raw.trimmedSIP
            guard !piece.isEmpty else { return nil }
            guard let equals = piece.firstIndex(of: "=") else {
                return SIPURI.Parameter(name: String(piece))
            }
            let name = piece[..<equals].trimmedSIP
            let value = piece[piece.index(after: equals)...].trimmedSIP
            guard !name.isEmpty else { return nil }
            return SIPURI.Parameter(name: String(name), value: unquoted(value))
        }
    }

    /// Снимает обрамляющие кавычки и раскрывает экранирование внутри них.
    static func unquoted(_ text: Substring) -> String {
        guard text.count >= 2, text.first == "\"", text.last == "\"" else {
            return String(text)
        }
        let inner = text.dropFirst().dropLast()
        var result = ""
        result.reserveCapacity(inner.count)
        var escaped = false
        for character in inner {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// Оборачивает значение в кавычки, если без них оно было бы разобрано неверно.
    static func quotedIfNeeded(_ value: String) -> String {
        let needsQuotes = value.isEmpty || value.contains(where: {
            " \t\"\\,;:<>@()[]{}?=/".contains($0)
        })
        guard needsQuotes else { return value }
        var escaped = ""
        escaped.reserveCapacity(value.count + 2)
        for character in value {
            if character == "\"" || character == "\\" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return "\"\(escaped)\""
    }
}

extension Substring {
    /// Обрезка пробелов и табуляций без затаскивания Foundation в горячий путь.
    var trimmedSIP: Substring {
        var result = self
        while let first = result.first, first == " " || first == "\t" {
            result = result.dropFirst()
        }
        while let last = result.last, last == " " || last == "\t" {
            result = result.dropLast()
        }
        return result
    }
}

extension String {
    var trimmedSIP: String { String(Substring(self).trimmedSIP) }
}
