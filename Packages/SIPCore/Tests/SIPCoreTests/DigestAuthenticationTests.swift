import Foundation
import Testing
@testable import SIPCore

@Suite("Digest-аутентификация")
struct DigestAuthenticationTests {

    // Эталоны посчитаны независимо, системной утилитой md5, а не этим же кодом:
    //   HA1 = md5("100:asterisk:elite100")
    //   HA2 = md5("REGISTER:sip:127.0.0.1")
    //   без qop:  md5("HA1:1234abcd:HA2")
    //   с qop:    md5("HA1:1234abcd:00000001:0a4f113b:auth:HA2")
    private static let ha1 = "88bf37ae053364b41dc76a3ba43f376e"
    private static let ha2 = "7f83831edc2db7fc4a41972f6cbb2683"
    private static let responseWithoutQop = "612c4f24ca9a94443ae2f97d0bb86902"
    private static let responseWithQop = "12eedc275eeb4af2a1a9e8d118e3e6f4"
    private static let responseSessionAlgorithm = "5e81eb2c2e94a4600744b757753fb568"

    private let credentials = DigestAuthentication.Credentials(username: "100", password: "elite100")

    @Test("MD5 считается верно")
    func md5Vectors() {
        #expect(DigestAuthentication.md5Hex("100:asterisk:elite100") == Self.ha1)
        #expect(DigestAuthentication.md5Hex("REGISTER:sip:127.0.0.1") == Self.ha2)
        #expect(DigestAuthentication.md5Hex("") == "d41d8cd98f00b204e9800998ecf8427e")
    }

    @Test("Разбирает вызов в том виде, в каком его шлёт chan_sip")
    func parsesChanSipChallenge() throws {
        let challenge = try #require(DigestChallenge(
            headerValue: #"Digest algorithm=MD5, realm="asterisk", nonce="1234abcd""#
        ))
        #expect(challenge.realm == "asterisk")
        #expect(challenge.nonce == "1234abcd")
        #expect(challenge.normalizedAlgorithm == "MD5")
        #expect(challenge.qop.isEmpty)
        #expect(!challenge.stale)
        #expect(challenge.isSupported)
    }

    @Test("Разбирает вызов с qop, opaque и stale")
    func parsesRichChallenge() throws {
        let challenge = try #require(DigestChallenge(
            headerValue: #"Digest realm="asterisk", nonce="n1", opaque="op1", qop="auth,auth-int", stale=TRUE"#
        ))
        #expect(challenge.opaque == "op1")
        #expect(challenge.qop == ["auth", "auth-int"])
        #expect(challenge.stale, "stale означает «повтори с тем же паролем», а не «пароль неверный»")
    }

    @Test("Чужие схемы не притворяются понятыми")
    func rejectsNonDigest() {
        #expect(DigestChallenge(headerValue: "Basic realm=\"asterisk\"") == nil)
        #expect(DigestChallenge(headerValue: "Digest") == nil)
        #expect(DigestChallenge(headerValue: #"Digest nonce="n1""#) == nil, "без realm вызов бессмысленен")
        #expect(DigestChallenge(headerValue: #"Digest realm="r""#) == nil, "без nonce тоже")
    }

    @Test("Ответ без qop совпадает с эталоном")
    func responseWithoutQop() throws {
        let challenge = DigestChallenge(realm: "asterisk", nonce: "1234abcd")
        let value = try DigestAuthentication.authorizationValue(
            credentials: credentials,
            challenge: challenge,
            method: .register,
            digestURI: "sip:127.0.0.1"
        )

        #expect(value.hasPrefix("Digest "))
        #expect(value.contains(#"response="\#(Self.responseWithoutQop)""#))
        #expect(value.contains(#"username="100""#))
        #expect(value.contains(#"realm="asterisk""#))
        #expect(value.contains(#"nonce="1234abcd""#))
        #expect(value.contains(#"uri="sip:127.0.0.1""#))
        #expect(value.contains("algorithm=MD5"))
        #expect(!value.contains("qop="), "сервер qop не предлагал — не навязываем его сами")
        #expect(!value.contains("nc="))
    }

    @Test("Ответ с qop=auth совпадает с эталоном")
    func responseWithQop() throws {
        let challenge = DigestChallenge(realm: "asterisk", nonce: "1234abcd", qop: ["auth"])
        let value = try DigestAuthentication.authorizationValue(
            credentials: credentials,
            challenge: challenge,
            method: .register,
            digestURI: "sip:127.0.0.1",
            nonceCount: 1,
            cnonce: "0a4f113b"
        )

        #expect(value.contains(#"response="\#(Self.responseWithQop)""#))
        #expect(value.contains("qop=auth"))
        #expect(value.contains("nc=00000001"), "счётчик обязан быть восьмизначным hex")
        #expect(value.contains(#"cnonce="0a4f113b""#))
    }

    @Test("MD5-sess считает HA1 через nonce и cnonce")
    func sessionAlgorithm() throws {
        let challenge = DigestChallenge(realm: "asterisk", nonce: "1234abcd", algorithm: "MD5-sess")
        let value = try DigestAuthentication.authorizationValue(
            credentials: credentials,
            challenge: challenge,
            method: .register,
            digestURI: "sip:127.0.0.1",
            cnonce: "0a4f113b"
        )
        #expect(value.contains(#"response="\#(Self.responseSessionAlgorithm)""#))
        #expect(value.contains("algorithm=MD5-sess"))
    }

    @Test("Счётчик nonce попадает в ответ восьмизначным")
    func nonceCountFormatting() throws {
        let challenge = DigestChallenge(realm: "asterisk", nonce: "n", qop: ["auth"])
        let value = try DigestAuthentication.authorizationValue(
            credentials: credentials,
            challenge: challenge,
            method: .register,
            digestURI: "sip:host",
            nonceCount: 42,
            cnonce: "c"
        )
        #expect(value.contains("nc=0000002a"))
    }

    @Test("Неподдерживаемый алгоритм — ошибка, а не заведомо неверный ответ")
    func unsupportedAlgorithmThrows() {
        // RFC 8760 добавил SHA-256. chan_sip его не умеет, но если сервер
        // однажды потребует, лучше сказать это прямо, чем получить 403 без
        // объяснений.
        let challenge = DigestChallenge(realm: "asterisk", nonce: "n", algorithm: "SHA-256")
        #expect(!challenge.isSupported)
        #expect(throws: DigestAuthenticationError.unsupportedAlgorithm("SHA-256")) {
            _ = try DigestAuthentication.authorizationValue(
                credentials: credentials,
                challenge: challenge,
                method: .register,
                digestURI: "sip:host"
            )
        }
    }

    @Test("Неизвестный qop — тоже ошибка")
    func unsupportedQopThrows() {
        let challenge = DigestChallenge(realm: "asterisk", nonce: "n", qop: ["exotic"])
        #expect(throws: DigestAuthenticationError.self) {
            _ = try DigestAuthentication.authorizationValue(
                credentials: credentials,
                challenge: challenge,
                method: .register,
                digestURI: "sip:host"
            )
        }
    }

    @Test("Из предложенных qop выбирается auth")
    func qopSelection() {
        #expect(DigestAuthentication.selectQualityOfProtection(from: []) == nil)
        #expect(DigestAuthentication.selectQualityOfProtection(from: ["auth"]) == "auth")
        #expect(DigestAuthentication.selectQualityOfProtection(from: ["auth-int", "auth"]) == "auth")
        #expect(DigestAuthentication.selectQualityOfProtection(from: ["AUTH"]) == "auth")
        #expect(DigestAuthentication.selectQualityOfProtection(from: ["auth-int"]) == "auth-int")
        #expect(DigestAuthentication.selectQualityOfProtection(from: ["exotic"]) == nil)
    }

    @Test("407 требует Proxy-Authorization, а не Authorization")
    func proxyChallengeUsesProxyHeader() throws {
        var headers = SIPHeaders()
        headers.append("Proxy-Authenticate", #"Digest realm="proxy", nonce="n2""#)
        let response = SIPResponse(statusCode: 407, headers: headers)

        let challenges = response.authenticationChallenges
        #expect(challenges.count == 1)
        #expect(challenges.first?.responseHeader == "Proxy-Authorization")
        #expect(response.isAuthenticationRequired)
    }
}
