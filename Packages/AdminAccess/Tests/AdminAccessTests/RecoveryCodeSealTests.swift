import Foundation
import Testing

@testable import AdminAccess

/// Быстрая цена перебора: тесту нужна верность запечатывания, а не его
/// стоимость. Боевое число живёт в `KeyDerivation.defaultIterations`.
private let testIterations = 1_000

/// Запечатывание файла конфигурации кодом восстановления.
///
/// Проверять это надо тестом, а не глазами: «файл зашифрован» на вид неотличимо
/// от «файл зашифрован ключом, который никуда не годится», а цена ошибки —
/// пароль от добавочного, уехавший в чужие «Загрузки».
@Suite("Запечатывание кодом")
struct RecoveryCodeSealTests {

    private let code = "060397"

    @Test("Что запечатали, то и открывается")
    func roundTrip() throws {
        let payload = Data("пароль от добавочного".utf8)
        let seal = try RecoveryCodeSeal.seal(payload, code: code, iterations: testIterations)
        #expect(try seal.open(code: code) == payload)
    }

    @Test("Содержимого в файле не видно")
    func payloadIsNotVisible() throws {
        let secret = "СекретноеСлово"
        let seal = try RecoveryCodeSeal.seal(
            Data(secret.utf8), code: code, iterations: testIterations
        )

        // Ни строкой, ни её байтами внутри base64: файл уезжает в мессенджер
        // целиком, и «поискать глазами» — первое, что с ним сделают.
        let encoded = try JSONEncoder().encode(seal)
        #expect(!String(decoding: encoded, as: UTF8.self).contains(secret))
        #expect(seal.box.range(of: Data(secret.utf8)) == nil)
    }

    @Test("Чужой код не открывает")
    func wrongCodeFails() throws {
        let seal = try RecoveryCodeSeal.seal(
            Data("что-то".utf8), code: code, iterations: testIterations
        )
        #expect(throws: AdminAccessError.wrongRecoveryCode) {
            try seal.open(code: "111111")
        }
    }

    @Test("Правка файла руками даёт отказ, а не подменённое содержимое")
    func tamperingIsDetected() throws {
        var seal = try RecoveryCodeSeal.seal(
            Data("исходное".utf8), code: code, iterations: testIterations
        )
        // Тег GCM ломается от любого изменённого байта — на этом и держится
        // обещание «подсунуть своё нельзя».
        seal.box[seal.box.count - 1] ^= 0x01
        #expect(throws: AdminAccessError.wrongRecoveryCode) {
            try seal.open(code: code)
        }
    }

    @Test("Соль своя у каждого файла")
    func saltsDiffer() throws {
        let payload = Data("одно и то же".utf8)
        let first = try RecoveryCodeSeal.seal(payload, code: code, iterations: testIterations)
        let second = try RecoveryCodeSeal.seal(payload, code: code, iterations: testIterations)

        #expect(first.salt != second.salt)
        #expect(first.box != second.box, "два одинаковых слепка не должны совпадать побайтно")
        #expect(try first.open(code: code) == payload)
        #expect(try second.open(code: code) == payload)
    }

    @Test("Код принимается в том виде, в каком его пишет человек")
    func codeIsNormalized() throws {
        let seal = try RecoveryCodeSeal.seal(
            Data("что-то".utf8), code: "060397", iterations: testIterations
        )
        // Код может приехать из файла провижининга с разделителем — и это тот
        // же код, а не другой.
        #expect(try seal.open(code: "06-03-97") == Data("что-то".utf8))
        #expect(try seal.open(code: " 060 397 ") == Data("что-то".utf8))
    }

    @Test("Код не той длины отвергается сразу")
    func malformedCodeIsRejected() throws {
        #expect(throws: AdminAccessError.malformedRecoveryCode) {
            try RecoveryCodeSeal.seal(Data(), code: "12345", iterations: testIterations)
        }
        let seal = try RecoveryCodeSeal.seal(
            Data("что-то".utf8), code: code, iterations: testIterations
        )
        #expect(throws: AdminAccessError.malformedRecoveryCode) {
            try seal.open(code: "12345")
        }
    }

    @Test("Пустой файл читается как испорченный, а не как пустое содержимое")
    func emptySealIsMalformed() throws {
        let empty = RecoveryCodeSeal(iterations: testIterations, salt: Data(), box: Data())
        #expect(throws: AdminAccessError.malformedCredential) {
            try empty.open(code: code)
        }
    }

    // MARK: - Число итераций из файла

    @Test("Огромное число итераций не вешает открытие")
    func absurdIterationsDoNotHang() throws {
        var seal = try RecoveryCodeSeal.seal(
            Data("что-то".utf8), code: code, iterations: testIterations
        )
        // Так выглядит правка файла руками. Без потолка PBKDF2 честно
        // отработал бы два миллиарда итераций, и выглядело бы это как зависшее
        // приложение, а не как испорченный файл.
        seal.iterations = 2_000_000_000

        let started = Date()
        #expect(throws: AdminAccessError.wrongRecoveryCode) {
            try seal.open(code: code)
        }
        #expect(
            Date().timeIntervalSince(started) < 30,
            "потолок итераций не сработал — открытие ушло считать заказанное"
        )
    }

    @Test("Потолок режет только сверху")
    func boundKeepsSmallValues() {
        #expect(KeyDerivation.boundedIterations(1_000) == 1_000)
        #expect(KeyDerivation.boundedIterations(KeyDerivation.defaultIterations)
            == KeyDerivation.defaultIterations)
        #expect(KeyDerivation.boundedIterations(2_000_000_000) == KeyDerivation.maximumIterations)
    }
}
