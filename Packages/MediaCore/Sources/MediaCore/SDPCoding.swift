import Foundation

public struct SDPParseError: Error, Sendable, Equatable, CustomStringConvertible {

    public enum Kind: Sendable, Equatable {
        case empty
        case missingOrigin
        case malformedOrigin
        case malformedMedia
        case malformedConnection
        case unsupportedVersion
        case invalidEncoding
    }

    public let kind: Kind
    public let detail: String

    public var description: String { "\(kind): \(detail)" }
}

// MARK: - Разбор

public extension SessionDescription {

    init(parsing text: some StringProtocol) throws {
        // Как и в SIP, "\r\n" в Swift — один Character, поэтому split по "\n"
        // сам по себе не сработает. Нормализуем переводы строк заранее.
        let normalized = String(text).replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: true)

        guard !lines.isEmpty else {
            throw SDPParseError(kind: .empty, detail: "нет строк")
        }

        var origin: Origin?
        var sessionName = "-"
        var sessionConnection: Connection?
        var startTime: UInt64 = 0
        var stopTime: UInt64 = 0
        var sessionAttributes: [Attribute] = []
        var mediaSections: [MediaDescription] = []
        var unknown: [String] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.count >= 2, line.dropFirst().first == "=" else {
                if !line.isEmpty { unknown.append(line) }
                continue
            }

            let type = line.first!
            let value = String(line.dropFirst(2))

            switch type {
            case "v":
                guard value == "0" else {
                    throw SDPParseError(kind: .unsupportedVersion, detail: value)
                }

            case "o":
                origin = try Self.parseOrigin(value)

            case "s":
                sessionName = value

            case "c":
                let connection = try Self.parseConnection(value)
                // Строка c= до первой m= относится к сессии, после — к секции.
                if mediaSections.isEmpty {
                    sessionConnection = connection
                } else {
                    mediaSections[mediaSections.count - 1].connection = connection
                }

            case "t":
                let times = value.split(separator: " ", omittingEmptySubsequences: true)
                startTime = times.first.flatMap { UInt64($0) } ?? 0
                stopTime = times.count > 1 ? (UInt64(times[1]) ?? 0) : 0

            case "m":
                mediaSections.append(try Self.parseMedia(value))

            case "a":
                let attribute = Self.parseAttribute(value)
                if mediaSections.isEmpty {
                    sessionAttributes.append(attribute)
                } else {
                    mediaSections[mediaSections.count - 1].attributes.append(attribute)
                }

            default:
                // i=, u=, e=, p=, b=, k=, z=, r= — не нужны, но и не теряются.
                unknown.append(line)
            }
        }

        guard let origin else {
            throw SDPParseError(kind: .missingOrigin, detail: "нет строки o=")
        }

        self.init(
            origin: origin,
            sessionName: sessionName,
            connection: sessionConnection,
            startTime: startTime,
            stopTime: stopTime,
            attributes: sessionAttributes,
            media: mediaSections,
            unknownLines: unknown
        )
    }

    init(parsing data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw SDPParseError(kind: .invalidEncoding, detail: "тело не в UTF-8")
        }
        try self.init(parsing: text)
    }

    private static func parseOrigin(_ value: String) throws -> Origin {
        let parts = value.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 6,
              let sessionID = UInt64(parts[1]),
              let sessionVersion = UInt64(parts[2])
        else {
            throw SDPParseError(kind: .malformedOrigin, detail: value)
        }
        return Origin(
            username: String(parts[0]),
            sessionID: sessionID,
            sessionVersion: sessionVersion,
            networkType: String(parts[3]),
            addressType: String(parts[4]),
            address: String(parts[5])
        )
    }

    private static func parseConnection(_ value: String) throws -> Connection {
        let parts = value.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3 else {
            throw SDPParseError(kind: .malformedConnection, detail: value)
        }
        // У адреса может быть суффикс TTL или числа адресов: 224.0.0.1/127/2.
        let address = parts[2].split(separator: "/").first.map(String.init) ?? String(parts[2])
        return Connection(
            networkType: String(parts[0]),
            addressType: String(parts[1]),
            address: address
        )
    }

    private static func parseMedia(_ value: String) throws -> MediaDescription {
        let parts = value.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3 else {
            throw SDPParseError(kind: .malformedMedia, detail: value)
        }
        // Порт может идти с числом портов: 5004/2.
        let portField = parts[1].split(separator: "/").first ?? parts[1]
        guard let port = UInt16(portField) else {
            throw SDPParseError(kind: .malformedMedia, detail: value)
        }
        return MediaDescription(
            type: String(parts[0]),
            port: port,
            protocolName: String(parts[2]),
            formats: parts.dropFirst(3).compactMap { UInt8($0) }
        )
    }

    private static func parseAttribute(_ value: String) -> Attribute {
        guard let colon = value.firstIndex(of: ":") else {
            return Attribute(name: value)
        }
        return Attribute(
            name: String(value[..<colon]),
            value: String(value[value.index(after: colon)...])
        )
    }
}

// MARK: - Сериализация

public extension SessionDescription {

    /// Строки выводятся в порядке, который требует RFC 4566 §5. Порядок здесь не
    /// вопрос вкуса: часть реализаций разбирает SDP последовательно и на
    /// перестановке ломается.
    var encoded: String {
        var lines: [String] = []

        lines.append("v=0")
        lines.append("o=\(origin.username) \(origin.sessionID) \(origin.sessionVersion) \(origin.networkType) \(origin.addressType) \(origin.address)")
        lines.append("s=\(sessionName)")
        if let connection {
            lines.append("c=\(connection.networkType) \(connection.addressType) \(connection.address)")
        }
        lines.append("t=\(startTime) \(stopTime)")

        for attribute in attributes {
            lines.append(Self.encode(attribute))
        }

        for section in media {
            var mediaLine = "m=\(section.type) \(section.port) \(section.protocolName)"
            for format in section.formats {
                mediaLine += " \(format)"
            }
            lines.append(mediaLine)

            if let connection = section.connection {
                lines.append("c=\(connection.networkType) \(connection.addressType) \(connection.address)")
            }
            for attribute in section.attributes {
                lines.append(Self.encode(attribute))
            }
        }

        return lines.map { $0 + "\r\n" }.joined()
    }

    var encodedData: Data {
        Data(encoded.utf8)
    }

    private static func encode(_ attribute: Attribute) -> String {
        if let value = attribute.value {
            "a=\(attribute.name):\(value)"
        } else {
            "a=\(attribute.name)"
        }
    }
}
