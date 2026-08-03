import Foundation

/// Кто сейчас управляет закрытыми настройками.
///
/// Пункт 3 роадмапа: локальный режим должен быть явным состоянием, а не
/// отсутствием синхронизации. Пока значение ровно одно, и это не бесполезное
/// поле, а место, где в M8 появится второе — без ломки формата настроек и без
/// поиска по коду мест, где «синхронизации нет» подразумевалось молча.
public enum AdminManagement: String, Codable, Sendable, Equatable, CaseIterable {

    /// Настройки задаёт администратор этой машины.
    case local

    /// Настройки приезжают из EliteDash. Появится в M8.
    case eliteDash

    public var title: String {
        switch self {
        case .local: "Локальный режим"
        case .eliteDash: "Управляется EliteDash"
        }
    }

    public var explanation: String {
        switch self {
        case .local:
            "Профили, макросы и политику защиты задаёт администратор этой машины."
        case .eliteDash:
            "Профили, макросы и политику защиты присылает EliteDash."
        }
    }
}

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

    /// Кто управляет настройками.
    public var management: AdminManagement

    /// Открыт ли режим прямо сейчас.
    public private(set) var isUnlocked: Bool

    /// Новое состояние — всегда закрытое.
    ///
    /// `isUnlocked` намеренно нельзя задать снаружи: иначе «открыть режим»
    /// сводилось бы к присваиванию нового значения, и проверка пароля
    /// превращалась бы в формальность, которую легко обойти по невнимательности.
    /// Открыть режим можно только через `unlock`, то есть только предъявив
    /// пароль или код.
    public init(credential: AdminCredential? = nil, management: AdminManagement = .local) {
        self.credential = credential
        self.management = management
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

    /// Вход по коду восстановления. Возвращает действующий пароль — его
    /// показывают администратору, а не подменяют молча новым.
    public mutating func unlock(recoveryCode: String) throws -> String {
        guard let credential else { throw AdminAccessError.malformedCredential }
        let password = try credential.password(recoveryCode: recoveryCode)
        isUnlocked = true
        return password
    }

    /// Выход из режима.
    public mutating func lock() {
        isUnlocked = false
    }

    /// Задать или сменить пароль.
    ///
    /// Смена требует открытого режима — иначе кнопка «сменить пароль» была бы
    /// обходом пароля. Первая установка открытого режима не требует: пока
    /// пароля нет, `allowsAdministration` и так истинно.
    public mutating func setPassword(
        _ password: String,
        recoveryCode: String = RecoveryCode.provisioned
    ) throws {
        guard allowsAdministration else { throw AdminAccessError.wrongPassword }
        credential = try AdminCredential(password: password, recoveryCode: recoveryCode)
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
    public mutating func restore(credential: AdminCredential?, management: AdminManagement) {
        self.credential = credential
        self.management = management
        isUnlocked = false
    }
}
