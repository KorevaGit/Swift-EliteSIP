import Foundation
import Testing
@testable import AdminAccess

private let testIterations = 1_000

@Suite("Состояние административного режима")
struct AdminAccessStateTests {

    private func state(password: String) throws -> AdminAccessState {
        var state = AdminAccessState()
        try state.setPassword(password)
        // `setPassword` считает боевым числом итераций; для тестов пересобираем
        // учётные данные дешёвыми, с тем же паролем.
        let cheap = try AdminCredential(password: password, iterations: testIterations)
        state.restore(credential: cheap)
        return state
    }

    @Test("Без пароля закрытая часть открыта")
    func unprotectedIsOpen() {
        let state = AdminAccessState()
        #expect(!state.isProtected)
        #expect(state.allowsAdministration)
    }

    @Test("С паролем закрытая часть закрыта, пока не вошли")
    func protectedIsClosed() throws {
        var state = try self.state(password: "Пароль")
        #expect(state.isProtected)
        #expect(!state.allowsAdministration)

        try state.unlock(password: "Пароль")
        #expect(state.allowsAdministration)
    }

    @Test("Чужой пароль не открывает и не оставляет режим открытым")
    func wrongPasswordKeepsItClosed() throws {
        var state = try self.state(password: "Пароль")
        #expect(throws: AdminAccessError.wrongPassword) {
            try state.unlock(password: "Не пароль")
        }
        #expect(!state.allowsAdministration)
    }

    @Test("Выход закрывает режим")
    func lockCloses() throws {
        var state = try self.state(password: "Пароль")
        try state.unlock(password: "Пароль")
        state.lock()
        #expect(!state.allowsAdministration)
    }

    @Test("Смена пароля из закрытого режима невозможна")
    func passwordChangeRequiresUnlock() throws {
        var state = try self.state(password: "Старый")
        #expect(throws: AdminAccessError.wrongPassword) {
            try state.setPassword("Новый")
        }
        #expect(throws: AdminAccessError.wrongPassword) {
            try state.removePassword()
        }
        #expect(state.isProtected)
    }

    @Test("Загрузка настроек всегда закрывает режим")
    func restoreLocks() throws {
        var state = try self.state(password: "Пароль")
        try state.unlock(password: "Пароль")
        #expect(state.allowsAdministration)

        let credential = try AdminCredential(password: "Пароль", iterations: testIterations)
        state.restore(credential: credential)
        #expect(!state.allowsAdministration)
    }

    @Test("Снятый пароль открывает настройки всем")
    func removedPasswordOpensSettings() throws {
        var state = try self.state(password: "Пароль")
        try state.unlock(password: "Пароль")
        try state.removePassword()
        #expect(!state.isProtected)
        #expect(state.allowsAdministration)

        state.lock()
        #expect(state.allowsAdministration)
    }
}
