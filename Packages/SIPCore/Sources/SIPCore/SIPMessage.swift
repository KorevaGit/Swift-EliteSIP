import Foundation

/// Общая часть запроса и ответа.
public protocol SIPMessageProtocol: Sendable {
    var headers: SIPHeaders { get set }
    var body: Data { get set }
    /// Стартовая строка без завершающего CRLF.
    var startLine: String { get }
}

public extension SIPMessageProtocol {

    var callID: String? { headers[SIPHeaderName.callID]?.trimmedSIP }

    /// CSeq — это номер И метод. Проверять надо оба: ответ с правильным номером
    /// но чужим методом относится к другой транзакции.
    var cseq: (number: Int, method: SIPMethod)? {
        guard let raw = headers[SIPHeaderName.cseq] else { return nil }
        let parts = raw.trimmedSIP.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2,
              let number = Int(parts[0]),
              let method = SIPMethod(name: parts[1])
        else { return nil }
        return (number, method)
    }

    var from: NameAddress? { headers[SIPHeaderName.from].flatMap { NameAddress($0) } }
    var to: NameAddress? { headers[SIPHeaderName.to].flatMap { NameAddress($0) } }

    /// Верхний Via — свой собственный для исходящего запроса и тот, по которому
    /// маршрутизируется ответ.
    var topVia: SIPVia? { headers.values(SIPHeaderName.via).first.flatMap { SIPVia($0) } }

    var vias: [SIPVia] { headers.values(SIPHeaderName.via).compactMap { SIPVia($0) } }

    var contacts: [NameAddress] {
        headers.values(SIPHeaderName.contact).compactMap { NameAddress($0) }
    }

    var expires: Int? { headers.integer(SIPHeaderName.expires) }

    var contentType: String? { headers[SIPHeaderName.contentType]?.trimmedSIP }

    /// Байты сообщения. Content-Length всегда приводится к фактической длине
    /// тела: расхождение здесь на потоковом транспорте рассинхронизирует поток
    /// и ломает все последующие сообщения.
    func encoded() -> Data {
        var headers = self.headers
        headers.set(SIPHeaderName.contentLength, to: String(body.count))

        var text = startLine
        text += "\r\n"
        text += headers.encoded
        text += "\r\n"

        var data = Data(text.utf8)
        data.append(body)
        return data
    }
}

// MARK: - Запрос

public struct SIPRequest: SIPMessageProtocol, Sendable, Hashable {

    public var method: SIPMethod
    public var uri: SIPURI
    public var headers: SIPHeaders
    public var body: Data

    public init(method: SIPMethod, uri: SIPURI, headers: SIPHeaders = SIPHeaders(), body: Data = Data()) {
        self.method = method
        self.uri = uri
        self.headers = headers
        self.body = body
    }

    public var startLine: String {
        "\(method.rawValue) \(uri) SIP/2.0"
    }
}

// MARK: - Ответ

public struct SIPResponse: SIPMessageProtocol, Sendable, Hashable {

    public enum Category: Sendable, Hashable {
        case provisional    // 1xx
        case success        // 2xx
        case redirect       // 3xx
        case clientError    // 4xx
        case serverError    // 5xx
        case globalError    // 6xx
    }

    public var statusCode: Int
    public var reasonPhrase: String
    public var headers: SIPHeaders
    public var body: Data

    public init(
        statusCode: Int,
        reasonPhrase: String? = nil,
        headers: SIPHeaders = SIPHeaders(),
        body: Data = Data()
    ) {
        self.statusCode = statusCode
        self.reasonPhrase = reasonPhrase ?? Self.defaultReasonPhrase(for: statusCode)
        self.headers = headers
        self.body = body
    }

    public var startLine: String {
        "SIP/2.0 \(statusCode) \(reasonPhrase)"
    }

    public var category: Category? {
        switch statusCode {
        case 100..<200: .provisional
        case 200..<300: .success
        case 300..<400: .redirect
        case 400..<500: .clientError
        case 500..<600: .serverError
        case 600..<700: .globalError
        default: nil
        }
    }

    public var isProvisional: Bool { category == .provisional }
    public var isSuccess: Bool { category == .success }
    /// Финальный ответ — любой, кроме 1xx: именно он завершает транзакцию.
    public var isFinal: Bool { statusCode >= 200 }

    /// Требуется аутентификация. 401 приходит от registrar, 407 — от прокси, и
    /// отвечать на них надо разными заголовками.
    public var isAuthenticationRequired: Bool {
        statusCode == 401 || statusCode == 407
    }

    static func defaultReasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 100: "Trying"
        case 180: "Ringing"
        case 183: "Session Progress"
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 407: "Proxy Authentication Required"
        case 408: "Request Timeout"
        case 415: "Unsupported Media Type"
        case 420: "Bad Extension"
        case 423: "Interval Too Brief"
        case 480: "Temporarily Unavailable"
        case 481: "Call/Transaction Does Not Exist"
        case 486: "Busy Here"
        case 487: "Request Terminated"
        case 488: "Not Acceptable Here"
        case 500: "Server Internal Error"
        case 503: "Service Unavailable"
        case 603: "Decline"
        default: "Unknown"
        }
    }
}

// MARK: - Сообщение

public enum SIPMessage: Sendable, Hashable {
    case request(SIPRequest)
    case response(SIPResponse)

    public var asRequest: SIPRequest? {
        if case .request(let request) = self { request } else { nil }
    }

    public var asResponse: SIPResponse? {
        if case .response(let response) = self { response } else { nil }
    }

    public var headers: SIPHeaders {
        switch self {
        case .request(let request): request.headers
        case .response(let response): response.headers
        }
    }

    public func encoded() -> Data {
        switch self {
        case .request(let request): request.encoded()
        case .response(let response): response.encoded()
        }
    }
}
