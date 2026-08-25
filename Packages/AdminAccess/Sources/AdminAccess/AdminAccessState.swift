import Foundation

// `AdminManagement` отсюда убран 25 августа 2026.
//
// Перечисление было о том, откуда пришли настройки: «локальный режим» против
// «настройки из файла конфигурации». Файла конфигурации больше нет, и второе
// значение стало недостижимым — а с одним оставшимся тип начал врать: машина,
// которой управляет панель, показывала бы «Локальный режим».
//
// Управляемость машины живёт теперь там, где ей и место, —
// `AppSettings.PanelSettings.mode`, рядом с предустановкой, ревизией и ключом
// канала. Этот пакет о панели не знает и знать не должен: он про пароль.

/// Административный доступ целиком: что помним между запусками и открыт ли
/// режим прямо сейчас.
///
/// Открытость сессии живёт здесь же, но не сохраняется — она уходит вместе с
/// окном настроек. Так решено в M7c: «до закрытия окна». Держать её в файле
/// значило бы однажды оставить рабочее место распахнутым после перезапуска, и
/// узнать об этом было бы неоткуда.
public struct AdminAccessState: Sendable, Equatable {

    /// Проверочное значение пароля. nil — пароль не задан.
    public private(set) var credential: AdminCredential?

    /// Открыт ли режим прямо сейчас.
    public private(set) var isUnlocked: Bool

    /// Новое состояние — всегда закрытое.
    ///
    /// `isUnlocked` намеренно нельзя задать снаружи: иначе «открыть режим»
    /// сводилось бы к присваиванию нового значения, и проверка пароля
    /// превращалась бы в формальность, которую легко обойти по невнимательности.
    /// Открыть режим можно только через `unlock`, то есть только предъявив
    /// пароль или код.
    public init(credential: AdminCredential? = nil) {
        self.credential = credential
        self.isUnlocked = false
    }

    /// Задан ли пароль.
    public var isProtected: Bool { credential != nil }

    /// Видна ли закрытая часть настроек.
    ///
    /// Пока пароль не задан — видна всем. Так решено: свежая машина
    /// настраивается с аккаунта, и начинать эту настройку с придумывания
    /// пароля значит, что первый же установщик пароль и не задаст.
    public var allowsAdministration: Bool { credential == nil || isUnlocked }

    /// Вход по паролю.
    @discardableResult
    public mutating func unlock(password: String) throws -> Bool {
        guard let credential else {
            // Пароля нет — открывать нечего, но и отказывать не за что.
            isUnlocked = true
            return true
        }
        guard credential.matches(password: password) else {
            throw AdminAccessError.wrongPassword
        }
        isUnlocked = true
        return true
    }

    // Входа по коду восстановления здесь больше нет.
    //
    // Код лежал открытым текстом в бандле каждого приложения, то есть
    // «восстановление» работало у всякого, кто вскрыл `.app`. Держался он на
    // решении «код показывает актуальный пароль»; теперь актуальный пароль
    // показывает панель, потому что оттуда он и приезжает.

    /// Выход из режима.
    public mutating func lock() {
        isUnlocked = false
    }

    /// Задать или сменить пароль.
    ///
    /// Смена требует открытого режима — иначе кнопка «сменить пароль» была бы
    /// обходом пароля. Первая установка открытого режима не требует: пока
    /// пароля нет, `allowsAdministration` и так истинно.
    public mutating func setPassword(_ password: String) throws {
        guard allowsAdministration else { throw AdminAccessError.wrongPassword }
        credential = try AdminCredential(password: password)
        isUnlocked = true
    }

    /// Снять пароль совсем.
    public mutating func removePassword() throws {
        guard allowsAdministration else { throw AdminAccessError.wrongPassword }
        credential = nil
        isUnlocked = true
    }

    /// Учётные данные из файла настроек.
    ///
    /// Отдельно от инициализатора: при загрузке режим всегда закрыт, чем бы ни
    /// был занят предыдущий запуск.
    public mutating func restore(credential: AdminCredential?) {
        self.credential = credential
        isUnlocked = false
    }
}
