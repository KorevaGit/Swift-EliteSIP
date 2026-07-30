import Foundation
import Testing
@testable import Diagnostics

/// Маскирование секретов.
///
/// Проверка приёмки M7a звучит как «в собранном архиве нет ни одного
/// `response=`», и держит её этот набор. Ошибка здесь стоит пароля от SIP-
/// аккаунта в чужом мессенджере, а заметить её на разработке нельзя: в журнале
/// всё выглядит правдоподобно ровно до того момента, когда файл читает чужой.
@Suite("Маскирование секретов")
struct LogRedactionTests {

    @Test("Ответ Digest не попадает в журнал")
    func digestResponseIsRedacted() {
        let line = """
        -> REGISTER Authorization: Digest username="100", realm="asterisk", \
        nonce="1a2b3c", uri="sip:127.0.0.1", response="5f4dcc3b5aa765d61d8327deb882cf99", algorithm=MD5
        """
        let redacted = LogRedaction.redact(line)

        #expect(!redacted.contains("5f4dcc3b5aa765d61d8327deb882cf99"))
        #expect(redacted.contains("response=\"скрыто\""))

        // Остальное обязано уцелеть: по realm и nonce разбирают, чем именно
        // сервер недоволен, и вырезать их — значит сделать журнал бесполезным.
        #expect(redacted.contains("username=\"100\""))
        #expect(redacted.contains("realm=\"asterisk\""))
        #expect(redacted.contains("nonce=\"1a2b3c\""))
        #expect(redacted.contains("algorithm=MD5"))
    }

    @Test("Ответ без кавычек маскируется тоже")
    func unquotedResponseIsRedacted() {
        let redacted = LogRedaction.redact("проверка response=5f4dcc3b, дальше текст")
        #expect(!redacted.contains("5f4dcc3b"))
        #expect(redacted.contains("response=скрыто"))
        #expect(redacted.contains("дальше текст"), "разбор не должен съедать хвост строки")
    }

    @Test("Регистр не спасает секрет")
    func matchIsCaseInsensitive() {
        for field in ["Response", "RESPONSE", "ReSpOnSe"] {
            let redacted = LogRedaction.redact("\(field)=\"secretvalue\"")
            #expect(!redacted.contains("secretvalue"), "поле \(field) осталось незамаскированным")
        }
    }

    @Test("Ключ SRTP не попадает в журнал")
    func srtpKeyIsRedacted() {
        let line = "a=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:d0RmdmcmVCspeEc3QGZiNWpVLFJhQX1cfHAwJSoj|2^20|1:32"
        let redacted = LogRedaction.redact(line)

        #expect(!redacted.contains("d0RmdmcmVCspeEc3QGZiNWpVLFJhQX1cfHAwJSoj"))
        #expect(!redacted.contains("2^20"), "срок жизни ключа маскируется вместе с ним")
        #expect(redacted.contains("inline:скрыто"))
        #expect(redacted.contains("AES_CM_128_HMAC_SHA1_80"), "имя набора остаётся: по нему видно профиль")
    }

    @Test("Пароли под любым из привычных имён")
    func passwordsAreRedacted() {
        let cases = [
            "password=elite100",
            "secret = elite100",
            "pwd=elite100",
            "token=elite100",
            "api_key=elite100",
        ]
        for line in cases {
            #expect(!LogRedaction.redact(line).contains("elite100"), "не замаскировано: \(line)")
        }
    }

    @Test("Обычные строки журнала не портятся")
    func ordinaryLinesSurvive() {
        let lines = [
            "<- INVITE от 2929, ответили 180",
            "медиа: RTP G722 на 192.168.1.221:10008",
            "защита: 1 нажатие, курсор двигался, вердикт «человек»",
            "звоню на 22998, RTP-порт 16384",
        ]
        for line in lines {
            #expect(LogRedaction.redact(line) == line, "строка изменилась: \(line)")
        }
    }

    @Test("Номера и SIP-логины остаются как есть")
    func numbersAreKept() {
        // Решение заказчика от 30 июля 2026: история хранит номер и SIP-логин,
        // значит и в журнале маскировать их незачем — те же данные лежат на той
        // же машине. Маскируются только секреты.
        let line = "<- INVITE от 2929 (AutoDialer) на 100"
        #expect(LogRedaction.redact(line) == line)
    }

    @Test("Поле без значения не ломает разбор")
    func emptyValueIsHandled() {
        #expect(LogRedaction.redact("response=") == "response=")
        #expect(LogRedaction.redact("response") == "response")
        #expect(LogRedaction.redact("inline:") == "inline:")
    }
}
