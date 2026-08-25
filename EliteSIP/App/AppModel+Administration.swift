import AdminAccess
import Foundation

/// Черновик закрытых настроек: окно «Управление» ничего не применяет до
/// нажатия «Сохранить».
///
/// **Зачем.** Правка закрытых настроек — не то же самое, что движение ползунка
/// громкости. Она объявляет машину настроенной вручную, и такое объявление
/// должно быть отдельным действием, а не побочным эффектом случайного клика.
/// Отсюда три требования, которые здесь и выполняются: ничего не пишется на
/// диск, пока окно открыто; «Сохранить» показывает предупреждение; закрытие с
/// несохранённым спрашивает, а не решает за человека.
///
/// **Почему снимок, а не отдельная модель черновика.** Формы закрытых вкладок
/// уже написаны против `model.settings`, и переписать полторы тысячи строк на
/// второй источник значило бы завести два способа читать настройку — то есть
/// однажды прочитать не тот. Вместо этого запись на диск придерживается, а
/// «Отменить» возвращает снимок, снятый при входе. В памяти правки живые: это
/// честнее и для проверки на слух, и для «Показать окно для проверки».
extension AppModel {

    /// Открыт ли черновик.
    var isEditingAdministration: Bool { administrationSnapshot != nil }

    /// Есть ли что терять при закрытии.
    var hasUnsavedAdministrationChanges: Bool {
        guard let administrationSnapshot else { return false }
        return settings != administrationSnapshot
            || pendingAdminPassword != nil
            || pendingAdminPasswordRemoval
    }

    /// Вход в окно «Управление». Вызывается после проверки пароля.
    func beginAdministration() {
        guard administrationSnapshot == nil else { return }
        administrationSnapshot = settings
        isHoldingSettingsWrites = true
        pendingAdminPassword = nil
        pendingAdminPasswordRemoval = false
    }

    /// «Сохранить»: применяет всё разом.
    ///
    /// Раньше здесь же объявлялся «локальный режим» — состояние, отвечавшее на
    /// «настройки местные или из файла конфигурации». Файла нет с 25 августа
    /// 2026, вопрос отпал, и `AdminManagement` убран целиком: управляемость
    /// машины живёт в `settings.panel`, а не рядом с паролем.
    func commitAdministration() {
        guard let snapshot = administrationSnapshot else { return }

        let historyChanged = settings.history != snapshot.history

        // Профили, удалённые в черновике. Их история уходит вместе с ними: она
        // ограничена профилем жёстко, и оставить её значило бы держать записи,
        // которые больше некому показать. Считается до применения, потому что
        // после в настройках этих профилей уже нет.
        let survivors = Set(settings.profiles.profiles.map(\.id))
        let removedProfiles = snapshot.profiles.profiles.map(\.id).filter { !survivors.contains($0) }

        isHoldingSettingsWrites = false
        administrationSnapshot = nil

        // Пароль SIP отдельного применения не требует: он поле настроек, и
        // уезжает на диск вместе с ними — тем же `persistSettings` ниже.
        // Административный пароль живёт не в файле, поэтому применяется здесь.
        if pendingAdminPasswordRemoval {
            try? removeAdminPassword()
            pendingAdminPasswordRemoval = false
        } else if let pendingAdminPassword {
            try? setAdminPassword(pendingAdminPassword)
            self.pendingAdminPassword = nil
        }

        persistSettings()

        // История применяется только здесь, а не по ходу правки: уменьшенный
        // срок сразу удаляет записи, и «Отменить» их уже не вернёт. Это
        // единственная закрытая настройка, у которой правка в черновике имела
        // бы необратимые последствия.
        if historyChanged {
            openHistoryIfNeeded()
        }

        // После `openHistoryIfNeeded`: та могла завести хранилище заново, и
        // удалять надо из того, которое сейчас открыто.
        deleteHistory(ofProfiles: removedProfiles)

        append(
            level: .info,
            message: "закрытые настройки сохранены"
        )

        // Ровно то, что раньше делала `savePassword`: как только у профиля
        // появился пароль, выходим на линию сами. Ручного «Подключить» в панели
        // нет, и без этого администратор сохранил бы настройку и оставил
        // оператора смотреть на «Профиль без пароля» до ближайшей смены сети.
        Task { await connectIfPossible() }
    }

    /// «Отменить»: возвращает всё как было при входе.
    func cancelAdministration() {
        guard let administrationSnapshot else { return }

        isHoldingSettingsWrites = false
        pendingAdminPassword = nil
        pendingAdminPasswordRemoval = false

        // Присваивание проходит через наблюдатель `settings`, и он запишет файл
        // — уже без придержки. Это верно: на диске сейчас лежит именно снимок,
        // и лишняя запись тем же содержимым безвредна.
        settings = administrationSnapshot
        self.administrationSnapshot = nil

        append(level: .info, message: "правки закрытых настроек отменены")
    }

    // MARK: - Отложенные пароли

    /// Административный пароль: в черновик. Пароль SIP своей отложенной
    /// копии не имеет — он лежит в `settings`, а их запись на диск уже
    /// придержана, и «Отменить» возвращает снимок вместе с ним.
    func stageAdminPassword(_ password: String) {
        pendingAdminPassword = password
        pendingAdminPasswordRemoval = false
    }

    func stageAdminPasswordRemoval() {
        pendingAdminPassword = nil
        pendingAdminPasswordRemoval = true
    }

    /// Будет ли пароль задан после сохранения.
    var isAdministrationProtectedIncludingDraft: Bool {
        if pendingAdminPasswordRemoval { return false }
        if let pendingAdminPassword { return !pendingAdminPassword.isEmpty }
        return isAdministrationProtected
    }
}
