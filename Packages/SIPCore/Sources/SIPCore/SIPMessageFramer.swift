import Foundation

/// Выделяет отдельные сообщения из потока байтов.
///
/// На UDP framer не нужен — там одна датаграмма равна одному сообщению. Он
/// существует ради TCP и TLS, где сообщения склеиваются и рвутся произвольно, а
/// единственный признак конца — Content-Length.
public struct SIPMessageFramer: Sendable {

    /// Предел на одно сообщение. Без него сломанный или враждебный peer,
    /// который никогда не пришлёт пустую строку, растит буфер до OOM.
    public static let defaultMaximumMessageSize = 128 * 1024

    public enum FramingError: Error, Sendable, Equatable {
        /// Заголовки не закончились в пределах допустимого размера.
        case messageTooLarge(bufferedBytes: Int)
        case malformedContentLength(String)
    }

    private var buffer = Data()
    private let maximumMessageSize: Int

    public init(maximumMessageSize: Int = SIPMessageFramer.defaultMaximumMessageSize) {
        self.maximumMessageSize = maximumMessageSize
    }

    public var bufferedByteCount: Int { buffer.count }

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// Возвращает байты следующего целого сообщения или nil, если данных пока мало.
    public mutating func nextMessageData() throws -> Data? {
        discardLeadingLineBreaks()

        guard !buffer.isEmpty else { return nil }

        guard let boundary = SIPParser.headerTerminatorRange(in: buffer) else {
            // Заголовки ещё не закончились. Это нормально, пока буфер разумного
            // размера.
            if buffer.count > maximumMessageSize {
                throw FramingError.messageTooLarge(bufferedBytes: buffer.count)
            }
            return nil
        }

        let headerData = buffer[buffer.startIndex..<boundary.lowerBound]
        let contentLength = try declaredContentLength(in: headerData)

        let headerByteCount = boundary.upperBound - buffer.startIndex

        // Сложение с проверкой переполнения, а не обычное. `Content-Length`
        // приходит из сети, и `Int("9223372036854775807")` разбирается успешно:
        // обычное сложение с длиной заголовков переполнилось бы и уронило
        // процесс на трапе — одним пакетом, ещё до всякого разбора.
        let (totalByteCount, overflowed) = headerByteCount.addingReportingOverflow(contentLength)
        if overflowed || totalByteCount > maximumMessageSize {
            throw FramingError.messageTooLarge(bufferedBytes: overflowed ? Int.max : totalByteCount)
        }
        guard buffer.count >= totalByteCount else { return nil }

        let message = Data(buffer.prefix(totalByteCount))
        // Пересобираем Data, а не removeFirst: срез Data сохраняет исходный
        // startIndex, и дальше арифметика по индексам начинает врать.
        buffer = Data(buffer.dropFirst(totalByteCount))
        return message
    }

    /// Разбирает все накопленные целые сообщения.
    public mutating func drainMessages() throws -> [SIPMessage] {
        var result: [SIPMessage] = []
        while let data = try nextMessageData() {
            result.append(try SIPParser.parse(data))
        }
        return result
    }

    // MARK: - Внутреннее

    /// Убирает ведущие CRLF.
    ///
    /// На надёжном транспорте одинокий CRLF — это keep-alive «ping» (RFC 5626),
    /// а не сообщение. Если не выбросить его здесь, парсер получит мусор и
    /// решит, что соединение сломано.
    private mutating func discardLeadingLineBreaks() {
        var skip = 0
        for byte in buffer {
            guard byte == 0x0D || byte == 0x0A else { break }
            skip += 1
        }
        if skip > 0 {
            buffer = Data(buffer.dropFirst(skip))
        }
    }

    private func declaredContentLength(in headerData: Data) throws -> Int {
        guard let text = String(data: headerData, encoding: .utf8) else {
            // Заголовки не в UTF-8 — пусть с этим разбирается парсер, framer
            // отдаёт сообщение как есть, считая тело пустым.
            return 0
        }

        for line in SIPParser.unfolded(text).dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = SIPHeaderName.canonical(line[..<colon])
            guard name == SIPHeaderName.contentLength else { continue }

            let raw = line[line.index(after: colon)...].trimmedSIP
            guard let value = Int(raw), value >= 0 else {
                throw FramingError.malformedContentLength(String(raw))
            }
            return value
        }

        // Content-Length обязателен на потоковом транспорте, но его отсутствие
        // трактуем как пустое тело: это не повод рвать соединение.
        return 0
    }
}
