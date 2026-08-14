import Foundation

// не переводится: разбор сообщения — трасса протокола.

public struct SIPParseError: Error, Sendable, Equatable, CustomStringConvertible {

    public enum Kind: Sendable, Equatable {
        case empty
        case malformedStartLine
        case unsupportedVersion
        case malformedHeader
        case unknownMethod
        case invalidRequestURI
        case invalidStatusCode
        case missingHeaderTerminator
        case truncatedBody
        case invalidEncoding
    }

    public let kind: Kind
    public let detail: String

    public var description: String { "\(kind): \(detail)" }
}

public enum SIPParser {

    /// Разбирает одно полное сообщение.
    ///
    /// Тело возвращается сырыми байтами: заголовки в SIP текстовые, а тело —
    /// нет (в нашем случае SDP тоже текст, но декодировать его должен тот, кто
    /// знает Content-Type).
    public static func parse(_ data: Data) throws -> SIPMessage {
        guard !data.isEmpty else {
            throw SIPParseError(kind: .empty, detail: "нет данных")
        }

        guard let boundary = headerTerminatorRange(in: data) else {
            throw SIPParseError(kind: .missingHeaderTerminator, detail: "не найден пустой перевод строки после заголовков")
        }

        let headerData = data[data.startIndex..<boundary.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw SIPParseError(kind: .invalidEncoding, detail: "заголовки не в UTF-8")
        }

        var lines = unfolded(headerText)
        guard let startLine = lines.first, !startLine.isEmpty else {
            throw SIPParseError(kind: .malformedStartLine, detail: "пустая стартовая строка")
        }
        lines.removeFirst()

        var headers = SIPHeaders()
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw SIPParseError(kind: .malformedHeader, detail: "нет двоеточия: \(line)")
            }
            let name = line[..<colon].trimmedSIP
            guard !name.isEmpty else {
                throw SIPParseError(kind: .malformedHeader, detail: "пустое имя заголовка: \(line)")
            }
            let value = line[line.index(after: colon)...].trimmedSIP
            headers.append(String(name), String(value))
        }

        let bodyData = Data(data[boundary.upperBound...])
        let body: Data
        if let declared = headers.integer(SIPHeaderName.contentLength) {
            guard declared >= 0 else {
                throw SIPParseError(kind: .malformedHeader, detail: "отрицательный Content-Length")
            }
            guard bodyData.count >= declared else {
                throw SIPParseError(
                    kind: .truncatedBody,
                    detail: "объявлено \(declared) байт, получено \(bodyData.count)"
                )
            }
            body = bodyData.prefix(declared)
        } else {
            body = bodyData
        }

        if startLine.hasPrefix("SIP/") {
            return .response(try parseResponse(startLine: startLine, headers: headers, body: body))
        } else {
            return .request(try parseRequest(startLine: startLine, headers: headers, body: body))
        }
    }

    // MARK: - Стартовые строки

    private static func parseRequest(
        startLine: Substring,
        headers: SIPHeaders,
        body: Data
    ) throws -> SIPRequest {
        let parts = startLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3 else {
            throw SIPParseError(kind: .malformedStartLine, detail: String(startLine))
        }
        guard parts[parts.count - 1].uppercased() == "SIP/2.0" else {
            throw SIPParseError(kind: .unsupportedVersion, detail: String(parts[parts.count - 1]))
        }
        guard let method = SIPMethod(name: parts[0]) else {
            throw SIPParseError(kind: .unknownMethod, detail: String(parts[0]))
        }
        // Request-URI не может содержать пробелов, так что склеивать середину
        // не нужно — но если их больше одного, строка битая.
        guard parts.count == 3, let uri = SIPURI(parts[1]) else {
            throw SIPParseError(kind: .invalidRequestURI, detail: String(parts[1]))
        }
        return SIPRequest(method: method, uri: uri, headers: headers, body: body)
    }

    private static func parseResponse(
        startLine: Substring,
        headers: SIPHeaders,
        body: Data
    ) throws -> SIPResponse {
        // Reason-phrase может содержать пробелы, поэтому режем максимум на 3 части.
        let parts = startLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else {
            throw SIPParseError(kind: .malformedStartLine, detail: String(startLine))
        }
        guard parts[0].uppercased() == "SIP/2.0" else {
            throw SIPParseError(kind: .unsupportedVersion, detail: String(parts[0]))
        }
        guard let statusCode = Int(parts[1]), (100..<700).contains(statusCode) else {
            throw SIPParseError(kind: .invalidStatusCode, detail: String(parts[1]))
        }
        let reason = parts.count > 2 ? String(parts[2].trimmedSIP) : ""
        return SIPResponse(
            statusCode: statusCode,
            reasonPhrase: reason.isEmpty ? nil : reason,
            headers: headers,
            body: body
        )
    }

    // MARK: - Вспомогательное

    /// Ищет границу «заголовки / тело»: CRLFCRLF или, снисходительно, LFLF.
    ///
    /// Снисходительность здесь оправдана: своё мы всегда пишем с CRLF, но
    /// принимать от чужой реализации сообщение с LF дешевле, чем разбираться,
    /// почему звонок не идёт.
    static func headerTerminatorRange(in data: Data) -> Range<Data.Index>? {
        let bytes = [UInt8](data)
        let start = data.startIndex

        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0D,
               index + 3 < bytes.count,
               bytes[index + 1] == 0x0A, bytes[index + 2] == 0x0D, bytes[index + 3] == 0x0A {
                return (start + index)..<(start + index + 4)
            }
            if bytes[index] == 0x0A,
               index + 1 < bytes.count,
               bytes[index + 1] == 0x0A {
                return (start + index)..<(start + index + 2)
            }
            index += 1
        }
        return nil
    }

    /// Разворачивает свёрнутые заголовки: продолжение строки начинается с
    /// пробела или табуляции и по RFC 3261 §7.3.1 склеивается с предыдущей.
    static func unfolded(_ text: String) -> [Substring] {
        // Нормализация переводов строк здесь не косметика, а необходимость:
        // в Swift "\r\n" — это ОДИН Character (расширенный грапемный кластер),
        // поэтому split(separator: "\n") по CRLF не находит ничего, и весь блок
        // заголовков остаётся одной строкой. Поиск подстроки "\r\n" кластер
        // видит, поэтому заменяем её на одиночный перевод строки заранее.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")

        var joined: [String] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t", !joined.isEmpty {
                joined[joined.count - 1] += " " + String(line.trimmedSIP)
            } else {
                joined.append(String(line))
            }
        }

        return joined.map { Substring($0) }
    }
}
