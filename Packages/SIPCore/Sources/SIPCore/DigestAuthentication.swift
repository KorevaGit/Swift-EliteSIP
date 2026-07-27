import CryptoKit
import Foundation

/// Разобранный вызов на аутентификацию из WWW-Authenticate или Proxy-Authenticate.
public struct DigestChallenge: Sendable, Hashable {

    public var realm: String
    public var nonce: String
    public var opaque: String?
    /// nil означает MD5 — так по RFC 2617, и именно так шлёт chan_sip.
    public var algorithm: String?
    public var qop: [String]
    /// Сервер говорит, что nonce устарел: повторить можно тем же паролем,
    /// а не считать это ошибкой логина.
    public var stale: Bool

    public init(
        realm: String,
        nonce: String,
        opaque: String? = nil,
        algorithm: String? = nil,
        qop: [String] = [],
        stale: Bool = false
    ) {
        self.realm = realm
        self.nonce = nonce
        self.opaque = opaque
        self.algorithm = algorithm
        self.qop = qop
        self.stale = stale
    }

    /// Разбирает одно значение заголовка вида `Digest realm="…", nonce="…"`.
    public init?(headerValue: some StringProtocol) {
        let text = Substring(String(headerValue)).trimmedSIP

        // Отделяем схему от параметров по первому пробелу.
        guard let space = text.firstIndex(of: " ") else { return nil }
        guard text[..<space].caseInsensitiveCompare("Digest") == .orderedSame else {
            // Basic и прочее не поддерживаем сознательно: SIP-серверы им не
            // пользуются, а молчаливая поддержка спрятала бы реальную проблему.
            return nil
        }

        var realm: String?
        var nonce: String?
        var opaque: String?
        var algorithm: String?
        var qop: [String] = []
        var stale = false

        // Запятые здесь разделяют параметры одного вызова, а не разные значения,
        // и внутри кавычек их игнорировать обязательно.
        for piece in SIPLexer.splitTopLevel(text[text.index(after: space)...], separator: ",") {
            let parameter = piece.trimmedSIP
            guard let equals = parameter.firstIndex(of: "=") else { continue }
            let name = parameter[..<equals].trimmedSIP.lowercased()
            let value = SIPLexer.unquoted(parameter[parameter.index(after: equals)...].trimmedSIP)

            switch name {
            case "realm": realm = value
            case "nonce": nonce = value
            case "opaque": opaque = value
            case "algorithm": algorithm = value
            case "stale": stale = value.caseInsensitiveCompare("true") == .orderedSame
            case "qop":
                qop = value.split(separator: ",").map { String($0.trimmedSIP) }
            default: break
            }
        }

        guard let realm, let nonce else { return nil }
        self.realm = realm
        self.nonce = nonce
        self.opaque = opaque
        self.algorithm = algorithm
        self.qop = qop
        self.stale = stale
    }

    /// Нормализованный алгоритм.
    public var normalizedAlgorithm: String {
        (algorithm ?? "MD5").uppercased()
    }

    public var isSupported: Bool {
        normalizedAlgorithm == "MD5" || normalizedAlgorithm == "MD5-SESS"
    }
}

public enum DigestAuthenticationError: Error, Sendable, Equatable {
    /// Сервер требует алгоритм, которого мы не умеем (например SHA-256 по
    /// RFC 8760). Лучше сказать это явно, чем послать заведомо неверный ответ и
    /// получить 403 без объяснений.
    case unsupportedAlgorithm(String)
    case unsupportedQualityOfProtection([String])
}

/// Вычисление ответа на digest-вызов (RFC 2617, в объёме, который использует SIP).
public enum DigestAuthentication {

    public struct Credentials: Sendable, Hashable {
        public var username: String
        public var password: String

        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    /// Собирает значение для заголовка Authorization или Proxy-Authorization.
    ///
    /// - Parameters:
    ///   - digestURI: значение параметра `uri`. Это Request-URI запроса как
    ///     строка, и она должна совпадать байт в байт с тем, что уйдёт в
    ///     стартовой строке — сервер считает хеш от неё же.
    ///   - nonceCount: счётчик использования nonce, нужен только при qop.
    public static func authorizationValue(
        credentials: Credentials,
        challenge: DigestChallenge,
        method: SIPMethod,
        digestURI: String,
        nonceCount: Int = 1,
        cnonce: String? = nil,
        body: Data = Data()
    ) throws -> String {
        guard challenge.isSupported else {
            throw DigestAuthenticationError.unsupportedAlgorithm(challenge.normalizedAlgorithm)
        }

        let selectedQop = selectQualityOfProtection(from: challenge.qop)
        if !challenge.qop.isEmpty && selectedQop == nil {
            throw DigestAuthenticationError.unsupportedQualityOfProtection(challenge.qop)
        }

        let clientNonce = cnonce ?? SIPToken.random(length: 16)

        var ha1 = md5Hex("\(credentials.username):\(challenge.realm):\(credentials.password)")
        if challenge.normalizedAlgorithm == "MD5-SESS" {
            ha1 = md5Hex("\(ha1):\(challenge.nonce):\(clientNonce)")
        }

        let ha2: String
        if selectedQop == "auth-int" {
            ha2 = md5Hex("\(method.rawValue):\(digestURI):\(md5Hex(body))")
        } else {
            ha2 = md5Hex("\(method.rawValue):\(digestURI)")
        }

        let nonceCountText = String(format: "%08x", nonceCount)

        let response: String
        if let selectedQop {
            response = md5Hex("\(ha1):\(challenge.nonce):\(nonceCountText):\(clientNonce):\(selectedQop):\(ha2)")
        } else {
            response = md5Hex("\(ha1):\(challenge.nonce):\(ha2)")
        }

        var parameters: [String] = [
            "username=\(quoted(credentials.username))",
            "realm=\(quoted(challenge.realm))",
            "nonce=\(quoted(challenge.nonce))",
            "uri=\(quoted(digestURI))",
            "response=\(quoted(response))",
        ]

        // algorithm передаём без кавычек — это token, и некоторые реализации
        // спотыкаются на закавыченном значении.
        parameters.append("algorithm=\(challenge.normalizedAlgorithm == "MD5-SESS" ? "MD5-sess" : "MD5")")

        if let selectedQop {
            parameters.append("qop=\(selectedQop)")
            parameters.append("nc=\(nonceCountText)")
            parameters.append("cnonce=\(quoted(clientNonce))")
        }
        if let opaque = challenge.opaque {
            parameters.append("opaque=\(quoted(opaque))")
        }

        return "Digest " + parameters.joined(separator: ", ")
    }

    /// Из предложенных сервером вариантов выбираем `auth`: `auth-int` требует
    /// хеша тела и ничего не даёт против MITM, а поддержка обоих удваивает
    /// поверхность для ошибок.
    static func selectQualityOfProtection(from offered: [String]) -> String? {
        guard !offered.isEmpty else { return nil }
        if offered.contains(where: { $0.caseInsensitiveCompare("auth") == .orderedSame }) {
            return "auth"
        }
        if offered.contains(where: { $0.caseInsensitiveCompare("auth-int") == .orderedSame }) {
            return "auth-int"
        }
        return nil
    }

    // MARK: - Хеши

    static func md5Hex(_ text: String) -> String {
        md5Hex(Data(text.utf8))
    }

    static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

public extension SIPResponse {

    /// Вызовы на аутентификацию из ответа.
    ///
    /// 401 приходит от registrar и требует Authorization, 407 — от прокси и
    /// требует Proxy-Authorization. Путать их нельзя, поэтому возвращаем вместе
    /// с именем заголовка, которым надо отвечать.
    var authenticationChallenges: [(challenge: DigestChallenge, responseHeader: String)] {
        var result: [(DigestChallenge, String)] = []

        for value in headers.values(SIPHeaderName.wwwAuthenticate) {
            if let challenge = DigestChallenge(headerValue: value) {
                result.append((challenge, SIPHeaderName.authorization))
            }
        }
        for value in headers.values(SIPHeaderName.proxyAuthenticate) {
            if let challenge = DigestChallenge(headerValue: value) {
                result.append((challenge, SIPHeaderName.proxyAuthorization))
            }
        }
        return result
    }
}
