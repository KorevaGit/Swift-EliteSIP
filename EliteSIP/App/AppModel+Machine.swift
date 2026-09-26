import AppKit
import Foundation
import PanelLink
import SIPCore

extension AppModel {

    /// Чем кончилось применение конфигурации из Spark.
    enum ConfigOutcome: Equatable {
        /// Ревизия не новее применённой — делать нечего.
        case unchanged
        /// Применено. `presetChanged` — машину перевели на другую
        /// предустановку, и файл предустановок надо спросить заново.
        case applied(presetChanged: Bool)
        /// Меняется номер или SIP-пароль, а идёт разговор: ждём его конца.
        case deferred
    }

    /// Применяет конфигурацию машины, приехавшую из Spark.
    ///
    /// Номер, SIP-пароль, подпись, формат работы, предустановка и пароль
    /// настроек — всё, что администратор поправил у сотрудника в Spark.
    /// Машина применяет это сама, без участия человека: так стажёр становится
    /// менеджером, а сменивший добавочный — звонит с нового.
    ///
    /// **Перерегистрация ждёт конца разговора.** Смена номера или пароля
    /// снимает регистрацию и поднимает её заново — посреди звонка это кладёт
    /// трубку за оператора. Отложенное живёт в памяти: выйди приложение, та же
    /// ревизия приедет снова следующим опросом, потому что применённой она не
    /// записана.
    @discardableResult
    func applyMachineConfig(_ config: MachineConfig) -> ConfigOutcome {
        guard config.installationID == settings.panel.installationID,
              config.revision > settings.panel.appliedConfigRevision
        else { return .unchanged }

        let profile = settings.profiles.active
        let site = siteFor(workFormat: config.workFormat) ?? profile.site
        let accountChanged = profile.account.username != config.number
            || profile.password != config.sipPassword
            || profile.site != site
        if accountChanged, isInCall {
            pendingConfig = config
            append(level: .info,
                   message: "настройки из Spark (ревизия \(config.revision)) ждут конца разговора")
            return .deferred
        }
        pendingConfig = nil

        let numberBefore = profile.account.username
        var updated = profile
        updated.account.username = config.number
        updated.account.authUsername = nil
        updated.password = config.sipPassword
        updated.site = site
        if !config.employee.isEmpty { updated.label = config.employee }
        settings.profiles.active = updated
        // Площадка выбирает адрес АТС из пары: смена формата работы обязана
        // увести профиль на другой адрес, а не остаться строкой в настройках.
        alignProfileAddress(previous: settings.siteAddresses)

        let presetChanged = !config.presetID.isEmpty && config.presetID != settings.panel.presetID
        if presetChanged {
            let was = settings.panel.presetName.isEmpty ? settings.panel.presetID : settings.panel.presetName
            settings.panel.presetID = config.presetID
            settings.panel.appliedRevision = 0
            append(level: .info, message: "Spark сменил предустановку машины: «\(was)» → «\(config.presetName)»")
        }
        if !config.presetName.isEmpty { settings.panel.presetName = config.presetName }
        settings.panel.mode = .managed
        settings.panel.appliedConfigRevision = config.revision
        applyPanelPassword(config.adminPassword)
        persistSettings()

        append(level: .info,
               message: "настройки из Spark применены: номер \(config.number), ревизия \(config.revision)")
        if accountChanged, numberBefore != config.number, !numberBefore.isEmpty {
            showPanelNotice(String(
                format: NSLocalizedString("Администратор сменил номер: %@", comment: "уведомление в панели"),
                config.number))
        }
        return .applied(presetChanged: presetChanged)
    }

    /// Разговор кончился — применить отложенную конфигурацию.
    func applyPendingConfigIfIdle() -> ConfigOutcome {
        guard let config = pendingConfig, !isInCall else { return .unchanged }
        return applyMachineConfig(config)
    }

    /// Формат работы из Spark — площадка профиля. Неизвестное значение не
    /// трогает площадку.
    func siteFor(workFormat: String) -> SIPProfileSite? {
        switch workFormat {
        case "remote": return .remote
        case "office": return .office
        default: return nil
        }
    }

    /// Пароль «Управления» из Spark.
    ///
    /// Ставится и снимается без открытого «Управления»: у сотрудника за
    /// закрытой машиной прежнего пароля нет, а Spark подписанной конфигурацией
    /// говорит, какой пароль у машины. Пустой — «у предустановки пароля нет»,
    /// и прежний снимается.
    ///
    /// **Ставится только если изменился.** Иначе каждый заход писал бы строку
    /// в журнал и перевыводил ключ из пароля: PBKDF2 со ста пятьюдесятью
    /// тысячами итераций — это заметно на Catalina и не нужно ни для чего.
    func applyPanelPassword(_ password: String) {
        if password.isEmpty {
            guard adminAccess.isProtected else { return }
            do {
                try adminAccess.applyPanelPassword(nil)
                settings.admin.credential = nil
                append(level: .info, message: "административный пароль снят: у предустановки его нет")
            } catch {
                append(level: .warning, message: "административный пароль не снят: \(error.localizedDescription)")
            }
            return
        }
        guard adminAccess.credential?.matches(password: password) != true else { return }
        do {
            try adminAccess.applyPanelPassword(password)
            settings.admin.credential = adminAccess.credential
            append(level: .info, message: "административный пароль приехал из Spark")
        } catch {
            // Пароль не лёг — машина всё равно поднята и звонит. Ронять из-за
            // этого рабочее место незачем, но и молчать нельзя.
            append(level: .warning,
                   message: "административный пароль из Spark не применён: \(error.localizedDescription)")
        }
    }

    /// Сбрасывает машину по подписанному отзыву.
    ///
    /// **Чистка полная: не остаётся ничего.** Идёт она той же дорогой, что и
    /// «Сбросить машину» в «Обслуживании», — `resetMachine()`, — и это не
    /// экономия кода, а требование: два разных сброса разошлись бы на первой
    /// же новой настройке, и один из них однажды оставил бы на машине то, что
    /// другой уносит.
    ///
    /// Уносится всё: профили целиком, адреса площадок, стук, клавиши, очереди,
    /// конференция, административный пароль, история звонков и журнал. Машина
    /// возвращается в состояние сразу после установки и требует мастер заново.
    ///
    /// Первая редакция чистила только имя и пароль активного профиля да блок
    /// панели. Такая машина не могла зарегистрироваться — и при этом несла всю
    /// карту телефонии конторы: адрес АТС, стук, боевые коды перевода, все
    /// очереди, а если профилей было больше одного, то и их пароли целиком.
    /// Для «сотрудник уволился, ноутбук у него» это половина защиты.
    ///
    /// Цена полной чистки названа прямо: после неё разбирать ошибочный отзыв
    /// не по чему — журнал и история уходят вместе со всем остальным. Принято
    /// сознательно 26 августа 2026.
    func resetByRevocation(_ revocation: Revocation) {
        // В разговоре не сбрасываем: сброс снимает регистрацию и закрывает
        // диалоги, то есть кладёт трубку за оператора. Ждать безопасно —
        // отзыв лежит в канале и спрашивается каждые пятнадцать минут, так
        // что следующая же проверка вернётся сюда. Даже выход из приложения
        // ничего не теряет: объект никуда не девается.
        guard canResetMachine else {
            append(level: .warning,
                   message: "рабочее место отозвано, сброс ждёт конца разговора: "
                       + "машина \(revocation.installationID)")
            return
        }

        // Строка пишется до сброса, хотя журнал он и стирает: в те несколько
        // мгновений, что она живёт, её видит открытая «Диагностика». После
        // `resetMachine` своя строка про сброс попадёт уже в новый журнал.
        append(level: .warning,
               message: "рабочее место отозвано панелью — полная чистка: "
                   + "машина \(revocation.installationID)")

        resetMachine()
    }

}

// MARK: - Адрес АТС из предустановки

extension AppModel {

    /// Подтягивает адрес АТС к активному профилю после того, как приехала
    /// предустановка.
    ///
    /// Пара адресов (`siteAddresses`) — это настройка машины, а регистрируется
    /// профиль по своему `domain`, и одно из другого само не следует. До
    /// 26 августа 2026 адрес переезжал **только** при ручном переключении
    /// «Офис ↔ Удалённо»: предустановка клала пару в настройки и на этом
    /// останавливалась. На свежей машине, поднятой ключом, домен оставался
    /// пустым — номер есть, пароль есть, а регистрироваться некуда.
    ///
    /// - Parameter previous: пара, стоявшая до приезда предустановки. Нужна,
    ///   чтобы отличить «адрес из нашей пары, просто устарел» от «чужой адрес,
    ///   вписанный руками».
    func alignProfileAddress(previous: SIPSiteAddresses) {
        let addresses = settings.siteAddresses
        guard !addresses.isEmpty else { return }

        let profile = settings.profiles.active
        let current = profile.account.domain

        // Площадка выбирает адрес; `.automatic` не выбирает ничего, и тогда
        // берётся офисный. Это не догадка о том, где сидит человек, а
        // умолчание для машины, которую заводят: удалённого переключит
        // «Работа», и стук там решит сам адрес.
        let wanted = addresses.host(for: profile.site) ?? addresses.office
        guard !wanted.isEmpty, wanted != current else { return }

        // Переписывается пустой адрес и адрес из пары — прежней или новой.
        // Лабораторный `127.0.0.1` и чужая АТС остаются на месте: приезд
        // предустановки не должен незаметно уводить профиль на другой сервер.
        // То же правило, что у переключения площадки.
        guard current.isEmpty || previous.recognizes(current) || addresses.recognizes(current) else {
            append(level: .info,
                   message: "адрес АТС \(current) оставлен как есть: он не из пары предустановки")
            return
        }

        var account = profile.account
        account.domain = wanted
        guard settings.profiles.setAccount(account, for: profile.id) else { return }

        append(level: .info,
               message: current.isEmpty
                   ? "адрес АТС из предустановки: \(wanted)"
                   : "адрес АТС из предустановки: \(current) → \(wanted)")
    }
}
