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
    /// Здесь же машина объявляется настроенной вручную — если тронуто хоть
    /// одно поле, которым управляет панель. Объявление было и раньше, отвечало
    /// на «настройки местные или из файла конфигурации» и ушло вместе с файлом
    /// 25 августа 2026; с появлением панели (M9) его не вернули, и «Управление»
    /// полтора месяца обещало в предупреждении то, чего не делало.
    func commitAdministration() {
        guard let snapshot = administrationSnapshot else { return }

        let historyChanged = settings.history != snapshot.history
        let panelFieldsChanged = settings.differsInPanelManagedFields(from: snapshot)

        // Профили, удалённые в черновике. Их история уходит вместе с ними: она
        // ограничена профилем жёстко, и оставить её значило бы держать записи,
        // которые больше некому показать. Считается до применения, потому что
        // после в настройках этих профилей уже нет.
        let survivors = Set(settings.profiles.profiles.map(\.id))
        let removedProfiles = snapshot.profiles.profiles.map(\.id).filter { !survivors.contains($0) }

        isHoldingSettingsWrites = false
        administrationSnapshot = nil

        // Связка с панелью рвётся здесь — до записи на диск, чтобы уехать в
        // файл тем же заходом.
        //
        // Машина уходит в оффлайн, а не отвязывается насовсем: ключ канала и
        // предустановка остаются, и «Вернуться в онлайн» (`returnPanelOnline`)
        // возвращает её под панель без нового ключа. Раньше возврата не было
        // вовсе — решение пересмотрено 25 сентября 2026: выпускать ключ ради
        // отката одной неудачной правки оказалось дороже, чем стоит. Оффлайн
        // при этом назван явно и виден в «Техподдержке» и в «Аккаунте», так
        // что на вопрос «чем управляется место» ответ по-прежнему один.
        //
        // Рвут её только панельные поля. Административный пароль, срок хранения
        // истории, метка профиля, словарь очередей — местные настройки, панель
        // ими не управляет, и обрывать из-за них связь значило бы наказывать за
        // смену пароля потерей адресов АТС.
        if panelFieldsChanged, settings.panel.mode == .managed {
            settings.panel.mode = .manual
            settings.panel.wantsResync = false
            settings.incomingCall.isServerManaged = false
            append(
                level: .warning,
                message: "оффлайн: управляемые настройки правлены вручную, панель не применяется"
            )
        }

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

    // MARK: - Оффлайн и возврат в онлайн

    /// Машина ушла из-под панели правкой в «Управлении», но вернуть её можно:
    /// ключ канала и предустановка на месте.
    var isPanelOffline: Bool {
        let panel = settings.panel
        return panel.mode == .manual && !panel.presetID.isEmpty && panel.hasChannelKey
    }

    /// «Вернуться в онлайн»: снова слушать панель и наложить предустановку
    /// поверх местных правок — той же ревизией, если новой нет (`wantsResync`).
    ///
    /// Черновик «Управления» не мешает и не участвует: возврат пишется и в
    /// него, и в снимок, чтобы «Отменить» не увело машину обратно в оффлайн,
    /// а на диск уходит снимок — несохранённые правки на диск не попадают.
    /// Сама предустановка ляжет после закрытия окна: канал его ждёт.
    func returnPanelOnline() {
        guard isPanelOffline else { return }

        func online(_ value: inout AppSettings) {
            value.panel.mode = .managed
            value.panel.wantsResync = true
            value.incomingCall.isServerManaged = value.panel.isManaged
        }

        online(&settings)
        if var snapshot = administrationSnapshot {
            online(&snapshot)
            administrationSnapshot = snapshot
            do {
                try SettingsStore.save(snapshot)
            } catch {
                append(level: .error, message: "не удалось сохранить настройки: \(error.localizedDescription)")
            }
        } else {
            persistSettings()
        }

        append(level: .warning, message: "онлайн: машина снова под панелью, предустановка будет наложена заново")
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
