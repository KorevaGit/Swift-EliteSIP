import AppKit
import Foundation
import PanelLink
import SIPCore

extension AppModel {

    /// Применяет помашинный доступ, приехавший с канала.
    ///
    /// Административный пароль стал полем предустановки: у техподдержки своя
    /// предустановка со своим паролем. В общий файл предустановок он не едет —
    /// файл один на контору, и любой оператор прочитал бы там чужой пароль, —
    /// поэтому приезжает вот так, отдельным подписанным объектом.
    ///
    /// **Пароль ставится только если он изменился.** Иначе каждый заход на
    /// канал писал бы строку в журнал и перевыводил ключ из пароля: PBKDF2 со
    /// ста пятьюдесятью тысячами итераций раз в два часа — это заметно на
    /// Catalina и не нужно ни для чего.
    ///
    /// - Returns: сменилась ли предустановка машины — тогда файл предустановок
    ///   надо спросить заново, уже со своей новой записью.
    @discardableResult
    func applyMachineAccess(_ access: MachineAccess) -> Bool {
        applyAccessPassword(access)
        return adoptAssignedPreset(access)
    }

    /// Перепрошивка без ключа: панель переписала доступ машины на другую
    /// предустановку (учебная учётка стала менеджерской). Ключ, номер и ключ
    /// канала прежние — меняется только то, чью запись машина ищет в файле
    /// предустановок. Ревизия обнуляется: у новой предустановки свой счёт, и
    /// её первая ревизия может быть меньше применённой у старой.
    private func adoptAssignedPreset(_ access: MachineAccess) -> Bool {
        let assigned = access.presetID
        guard !assigned.isEmpty, settings.panel.isActivated, assigned != settings.panel.presetID else {
            return false
        }
        let was = settings.panel.presetName.isEmpty ? settings.panel.presetID : settings.panel.presetName
        settings.panel.presetID = assigned
        settings.panel.presetName = ""
        settings.panel.appliedRevision = 0
        persistSettings()
        // не переводится: строка журнала
        append(level: .info, message: "панель сменила предустановку машины: «\(was)» → \(assigned)")
        return true
    }

    private func applyAccessPassword(_ access: MachineAccess) {
        guard !access.adminPassword.isEmpty else { return }
        guard adminAccess.credential?.matches(password: access.adminPassword) != true else { return }

        do {
            try setAdminPassword(access.adminPassword)
            append(level: .info, message: "административный пароль приехал с панели")
        } catch {
            // Пароль не лёг — машина всё равно поднята и звонит. Ронять из-за
            // этого рабочее место незачем, но и молчать нельзя: «Управление»
            // на ней откроется прежним паролем, и знать об этом надо.
            append(level: .warning,
                   message: "административный пароль с панели не применён: \(error.localizedDescription)")
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

// MARK: - Перепрошивка

extension AppModel {

    /// Чем кончился ввод ключа перепрошивки.
    enum ReflashOutcome {
        /// Применено прямо сейчас.
        case applied
        /// Ждёт конца разговора.
        case deferred
    }

    /// Применяет пакет перепрошивки — или откладывает до конца разговора.
    ///
    /// Разговор не прерывается: перепрошивка снимает регистрацию и поднимает её
    /// заново, и делать это посреди звонка нельзя. Человеку при этом говорится
    /// «применится, когда положите трубку», а не «завершите вызов и повторите»:
    /// он стоит у экрана и ждёт ответа сейчас, а не готов повторять.
    ///
    /// Ключ к этому моменту уже сгорел — Worker столбит пакет в момент
    /// скачивания, — поэтому отказаться и попросить ввести позже нельзя: второй
    /// раз тот же ключ не сработает.
    @discardableResult
    func applyReflash(_ package: ActivationPackage) -> ReflashOutcome {
        guard !isInCall else {
            pendingReflash = package
            // Личность машины (installation_id и ключ канала) переводится
            // сразу, разговору она не мешает. Отложенный пакет живёт только в
            // памяти, а старую личность Spark гасит, как только увидит забор:
            // выйди приложение до конца разговора — машина осталась бы без
            // ключа канала, и отзыв до неё бы не дошёл.
            if package.installationID != settings.panel.installationID {
                previousReflashMachine = settings.panel.installationID
                settings.panel.installationID = package.installationID
                settings.panel.channelKey = package.channelKey
                persistSettings()
                append(level: .info,
                       message: "машина переведена на новый ключ до конца разговора: \(package.installationID)")
            }
            append(level: .info,
                   message: "перепрошивка ждёт конца разговора: "
                       + "предустановка «\(package.preset.name)»")
            return .deferred
        }

        pendingReflash = nil

        // Пакет применяется той же дорогой, что и при активации: правило
        // «номер, потом управляемые поля, потом память о панели» должно быть
        // одно на оба пути, а не два похожих.
        //
        // У ключа перепрошивки старого образца installation_id тот же самый.
        // У обычного ключа активации — новый: машина встаёт на новый ключ
        // целиком, а прежнюю строку Spark гасит по отметке о заборе.
        let switchedMachine = previousReflashMachine ?? settings.panel.installationID
        previousReflashMachine = nil
        applyActivation(package)
        persistSettings()

        append(level: .info,
               message: "рабочее место перепрошито: номер \(package.number), "
                   + "предустановка «\(package.preset.name)» ревизия \(package.preset.revision)")

        // Новый ключ активации — новая машина для панели: другой
        // installation_id и ключ канала. С этой минуты отзыв, доступ и
        // предустановки спрашиваются уже по новым; административный пароль
        // новой предустановки забираем сразу, а не через два часа.
        if switchedMachine != package.installationID {
            append(level: .info,
                   message: "машина переведена на новый ключ: \(switchedMachine) → \(package.installationID)")
            NSApp.sendAction(#selector(AppDelegate.checkPresetsNow(_:)), to: nil, from: nil)
        }
        return .applied
    }

    /// Разговор кончился — доложить отложенное.
    ///
    /// Зовётся тем же наблюдателем за линиями, что докладывает отложенную
    /// предустановку и возвращает предложение обновиться.
    func applyPendingReflashIfIdle() {
        guard let package = pendingReflash, !isInCall else { return }
        applyReflash(package)
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
