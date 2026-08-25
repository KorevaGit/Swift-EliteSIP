import Foundation
import Testing
@testable import AdminAccess

/// Быстрая цена перебора: тесту нужна верность проверки, а не её стоимость.
/// Боевое число итераций живёт в `KeyDerivation.defaultIterations` и здесь бы
/// стоило секунд на каждый случай.
private let testIterations = 1_000

@Suite("Административный пароль")
struct AdminCredentialTests {

    @Test("Свой пароль подходит, чужой — нет")
    func passwordVerification() throws {
        let credential = try AdminCredential(password: "Гладиолус7", iterations: testIterations)
        #expect(credential.matches(password: "Гладиолус7"))
        #expect(!credential.matches(password: "гладиолус7"))
        #expect(!credential.matches(password: "Гладиолус"))
        #expect(!credential.matches(password: ""))
    }

    @Test("Самого пароля в сохранённых данных нет")
    func passwordIsNotStoredInTheClear() throws {
        let password = "СекретноеСлово"
        let credential = try AdminCredential(password: password, iterations: testIterations)
        let encoded = try JSONEncoder().encode(credential)

        // Ни в каком виде: ни строкой, ни её байтами внутри base64-полей.
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains(password))
        #expect(!credential.loginHash.range(of: Data(password.utf8)).isSome)
    }

    @Test("Одинаковые пароли дают разные хеши: соль своя у каждой машины")
    func saltsDiffer() throws {
        let first = try AdminCredential(password: "Одно и то же", iterations: testIterations)
        let second = try AdminCredential(password: "Одно и то же", iterations: testIterations)
        #expect(first.loginSalt != second.loginSalt)
        #expect(first.loginHash != second.loginHash)
        // При этом оба проверяют один и тот же пароль.
        #expect(first.matches(password: "Одно и то же"))
        #expect(second.matches(password: "Одно и то же"))
    }

    @Test("Пустой пароль не заводится")
    func emptyPasswordRejected() {
        #expect(throws: AdminAccessError.emptyPassword) {
            _ = try AdminCredential(password: "", iterations: testIterations)
        }
    }

    @Test("Пустые учётные данные не открываются")
    func emptyCredentialRejected() {
        let credential = AdminCredential(
            iterations: testIterations,
            loginSalt: Data(),
            loginHash: Data()
        )
        #expect(!credential.matches(password: "что угодно"))
    }

    @Test("Учётные данные переживают запись и чтение файла настроек")
    func codableRoundTrip() throws {
        let credential = try AdminCredential(password: "Пароль", iterations: testIterations)
        let data = try JSONEncoder().encode(credential)
        let restored = try JSONDecoder().decode(AdminCredential.self, from: data)
        #expect(restored == credential)
        #expect(restored.matches(password: "Пароль"))
    }
}

private extension Optional {
    var isSome: Bool { self != nil }
}
