import AdminAccess
import Foundation

/// Административный режим: вход, выход и смена пароля.
///
/// Отдельным файлом, а не куском `AppModel`: у режима своя причина
/// существования (M7c) и свой инвариант — состояние в памяти и проверочное
/// значение в файле обязаны меняться вместе. Держать эти пять функций рядом
/// дешевле, чем однажды найти шестую, которая записала одно и забыла другое.
///
/// Каждый переход пишется в журнал с отметкой времени — этого требует пункт 4
/// роадмапа, и в M8 та же строка уедет в EliteDash. Отметку времени ставит
/// `LogEntry`, отдельного форматирования здесь нет.
extension AppModel {

    /// Видна ли закрытая часть настроек прямо сейчас.
    var allowsAdministration: Bool { adminAccess.allowsAdministration }

    /// Задан ли административный пароль.
    var isAdministrationProtected: Bool { adminAccess.isProtected }

    /// Вход по паролю.
    ///
    /// Бросает, а не возвращает `Bool`: у отказа есть текст, и показать его
    /// человеку — единственное, что окно ввода умеет делать с ошибкой.
    func unlockAdministration(password: String) throws {
        do {
            try adminAccess.unlock(password: password)
        } catch {
            // Неудачная попытка пишется тоже. Если рабочее место однажды
            // окажется открытым, разбирать будут по этим строкам, и «попыток
            // не было» — такой же ответ, как «их было двадцать».
            append(level: .warning, message: "административный режим: неверный пароль")
            throw error
        }
        append(level: .info, message: "административный режим открыт")
    }

    /// Вход по коду восстановления. Возвращает действующий пароль — его
    /// показывают администратору и предлагают сменить.
    func unlockAdministration(recoveryCode: String) throws -> String {
        let password: String
        do {
            password = try adminAccess.unlock(recoveryCode: recoveryCode)
        } catch {
            append(level: .warning, message: "административный режим: неверный код восстановления")
            throw error
        }
        // Сам пароль в журнал не попадает — ни здесь, ни маскированием: строки
        // с ним просто нет. Маскирование в `Diagnostics` вырезает известные
        // имена полей, а «пароль администратора» к ним не относится.
        append(level: .warning, message: "административный режим открыт кодом восстановления")
        return password
    }

    /// Выход из режима.
    ///
    /// Вызывается и по кнопке, и при закрытии окна настроек. Молчит, если
    /// режим и так закрыт: закрытие окна происходит каждый раз, и строка
    /// «режим закрыт» после каждого взгляда на громкость сделала бы журнал
    /// нечитаемым ровно в том месте, ради которого её пишут.
    func lockAdministration() {
        guard adminAccess.isUnlocked else { return }
        adminAccess.lock()
        append(level: .info, message: "административный режим закрыт")
    }

    /// Задать или сменить пароль.
    func setAdminPassword(_ password: String) throws {
        let wasProtected = adminAccess.isProtected
        try adminAccess.setPassword(password)
        settings.admin.credential = adminAccess.credential
        append(
            level: .info,
            message: wasProtected
                ? "административный пароль изменён"
                : "административный пароль задан, настройки закрыты"
        )
    }

    /// Снять пароль совсем — закрытая часть станет видна всем.
    func removeAdminPassword() throws {
        try adminAccess.removePassword()
        settings.admin.credential = nil
        append(level: .warning, message: "административный пароль снят, настройки открыты всем")
    }
}
