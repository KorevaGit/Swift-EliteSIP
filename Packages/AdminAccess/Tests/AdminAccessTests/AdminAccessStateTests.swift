import Foundation
import Testing
@testable import AdminAccess

private let testIterations = 1_000

@Suite("Состояние административного режима")
struct AdminAccessStateTests {

    private func state(password: String) throws -> AdminAccessState {
        var state = AdminAccessState()
        try state.setPassword(password, recoveryCode: "060397")
        // `setPassword` считает боевым числом итераций; для тестов пересобираем
        // учётные данные дешёвыми, сохранив ту же пару пароль + код.
        let cheap = try AdminCredential(
            password: password, recoveryCode: "060397", iterations: testIterations
        )
        state.restore(credential: cheap, management: .local)
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

    @Test("Код восстановления открывает режим и отдаёт действующий пароль")
    func recoveryOpensAndReveals() throws {
        var state = try self.state(password: "Пароль от АТС")
        let revealed = try state.unlock(recoveryCode: "060397")
        #expect(revealed == "Пароль от АТС")
        #expect(state.allowsAdministration)
    }

    @Test("Неверный код оставляет режим закрытым")
    func wrongRecoveryKeepsItClosed() throws {
        var state = try self.state(password: "Пароль")
        #expect(throws: AdminAccessError.wrongRecoveryCode) {
            _ = try state.unlock(recoveryCode: "111111")
        }
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
        state.restore(credential: credential, management: .local)
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

    @Test("Локальный режим — явное состояние, а не отсутствие синхронизации")
    func managementIsExplicit() {
        let state = AdminAccessState()
        #expect(state.management == .local)
        // Второе значение — заготовка под конфиг-файл (M8). Проверяется, чтобы
        // переход «конфиг → локально» не остался без состояния, из которого
        // переходить.
        #expect(AdminManagement.allCases == [.local, .configFile])
    }
}
