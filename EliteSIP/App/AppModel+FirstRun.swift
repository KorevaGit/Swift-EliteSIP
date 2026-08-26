import AdminAccess
import AppKit
import Foundation
import PanelLink
import SIPCore

/// Мастер первоначальной настройки: пропуск, применение, финал (этап 9).
///
/// Отдельным файлом, как административный режим и предустановки: у мастера свой
/// инвариант — **ничего не уходит на диск до конца**, — и держать три метода
/// рядом дешевле, чем однажды найти четвёртый, который записал половину.
extension AppModel {

    /// Тот ли административный пароль ввели пропуском.
    ///
    /// Сверяется с вшитым конфигом, а не с настройками машины: на первом запуске
    /// в настройках пароля нет вовсе — он как раз оттуда и приедет. Ограничения
    /// по числу попыток нет: пропуск знает только техподдержка, и запирать её
    /// после трёх опечаток значит запирать машину.
    ///
    /// Сборка без конфига не пускает никого: `secrets` в релизе `nil`, и это не
    /// забытая ветка, а требование к выпуску — см. M7e, пункт 7.
    func firstRunPassMatches(_ password: String) -> Bool {
        guard let secrets = Provisioning.secrets else { return false }
        return password == secrets.adminPassword
    }

    /// Запоминает выбранный язык и перезапускает приложение сразу.
    ///
    /// Перезапуск стоит здесь, на первом экране, а не перед финалом — решение
    /// 17 августа 2026. Язык берётся при старте процесса (`AppleLanguages`), и
    /// без перезапуска мастер продолжался бы на том, что угадала система: человек
    /// выбрал English, а следующий экран приезжал по-русски.
    ///
    /// Момент идеальный, и другого такого в мастере нет: на первом экране, кроме
    /// языка, ещё ничего не введено, а ни регистрации, ни разговора на первом
    /// запуске не существует — терять при перезапуске нечего.
    func applyFirstRunLanguage(_ language: LanguageSetting) {
        settings.firstRun = .languageChosen
        firstRun = .languageChosen
        persistSettings()
        // До перезапуска и синхронно: новый процесс поднимается раньше, чем
        // завершается старый, и незаписанный выбор он просто не увидит.
        language.apply()
        append(level: .info, message: "первоначальная настройка: выбран язык, приложение перезапускается")
        NSApp.sendAction(#selector(AppDelegate.relaunchApplication(_:)), to: nil, from: nil)
    }

    /// Живая проверка: встаёт ли этот добавочный на АТС прямо сейчас.
    ///
    /// Только для веток «предустановка» и «вручную». Ветка «Загрузить
    /// конфигурацию» проверки не проходит и не должна: там ничего не вводили
    /// руками, а пароль в слепке уже работал на исходной машине.
    ///
    /// Ничего не записывает и не трогает рабочий агент — см. `RegistrationProbe`.
    func probeFirstRunRegistration(flow: FirstRunFlow) async -> RegistrationProbe.Outcome? {
        guard let candidate = firstRunCandidate(flow: flow) else { return nil }

        return await RegistrationProbe.run(
            account: candidate.account,
            password: candidate.password,
            site: candidate.site,
            knock: settings.portKnock,
            acceptsAnyCertificate: settings.profiles.active.acceptsAnyTLSCertificate,
            log: { [weak self] level, message in
                Task { @MainActor in self?.append(level: level, message: message) }
            }
        )
    }

    /// Что именно проверять: собранная из черновика учётная запись.
    ///
    /// Собирается тем же способом, каким потом применится, — иначе проверка
    /// подтверждала бы не то, что уедет в настройки. Отсюда и площадка: в ветке
    /// предустановки она выбирает адрес из пары, в ручной остаётся `.automatic` и
    /// стук решает сам адрес.
    private func firstRunCandidate(
        flow: FirstRunFlow
    ) -> (account: SIPAccount, password: String, site: SIPProfileSite)? {
        switch flow.route {
        case .activationKey:
            // Живой проверки регистрации у ключевого пути нет намеренно: адрес
            // АТС приезжает в предустановке пакета, и собрать учётную запись до
            // применения значило бы разобрать предустановку дважды — здесь и в
            // `applyFirstRunWorkplace`. Второй разбор однажды разошёлся бы с
            // первым, и проверка подтверждала бы не то, что уедет в настройки.
            return nil

        case .manual:
            let host = flow.host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { return nil }
            return (
                SIPAccount(
                    username: flow.trimmedNumber,
                    displayName: "",
                    domain: host,
                    transport: .udp,
                    registrationExpires: 300
                ),
                flow.password,
                .automatic
            )
        }
    }

    /// Применяет всё, что набрано в мастере.
    ///
    /// Порядок здесь — не вкусовщина, а единственный работающий:
    ///
    /// 1. настройки рабочего места (ключ или ручной ввод);
    /// 2. административный пароль — из панели по ключу, из конфига вручную;
    /// 3. тема и стекло — поверх всего, что приехало из файла или снимка;
    /// 4. признак «пройден»;
    /// 5. запись на диск.
    ///
    /// - Returns: нужен ли перезапуск. Нужен он только ради корпуса: тот
    ///   выбирается при сборке окон, и живьём не меняется. Если стекло оставили
    ///   как было — а так будет почти всегда, — перезапуска не будет вовсе, и
    ///   мастер закончится тем, что откроется панель.
    @discardableResult
    func completeFirstRun(flow: FirstRunFlow) -> Bool {
        let chromeChanged = flow.plainChrome != settings.plainChrome
        applyFirstRunWorkplace(flow: flow)

        // Откуда берётся административный пароль, зависит от того, как
        // поднимали место, и это не мелочь.
        //
        // **По ключу — из панели.** Пароль стал полем предустановки: у
        // техподдержки своя предустановка со своим паролем, и вшитый в сборку
        // здесь означал бы, что машина встала не с тем паролем, который панель
        // считает действующим. Приезжает он помашинным объектом, забранным тем
        // же заходом, что и пакет, — см. `FirstRunFlow.openKey`.
        //
        // **Вручную — из конфига.** Это единственное, для чего вшитый пароль
        // ещё нужен: до панели такая машина не достаёт, и взять пароль ей
        // больше неоткуда.
        let password: String? = {
            if case .activationKey = flow.route { return flow.openedAccess?.adminPassword }
            return Provisioning.secrets?.adminPassword
        }()

        if let password, !password.isEmpty {
            do {
                let credential = try AdminCredential(password: password)
                settings.admin.credential = credential
                // Живому процессу об этом надо сказать отдельно.
                //
                // `AdminAccess` держит своё состояние и читает настройки только
                // при запуске (`AppModel.init`). Без этой строки приложение до
                // перезапуска считало, что пароля нет вовсе, — и «Управление»
                // открывалось **без вопроса**: `AdminUnlockView` на незащищённой
                // машине входит сам. Мастер при этом заканчивается без
                // перезапуска, если стекло не меняли, то есть дыра оставалась
                // открытой до конца смены. Нашлось на живой машине 17 августа 2026.
                adminAccess.restore(credential: credential)
            } catch {
                // Не молчим: без учётных данных машина остаётся с «Управлением»,
                // открытым всякому, а выглядит настроенной.
                append(level: .error, message: "не удалось применить административный пароль: \(error)")
            }
        } else {
            append(level: .error,
                   message: "административный пароль не задан: «Управление» открыто всякому")
        }

        settings.appearance = flow.appearance
        settings.plainChrome = flow.plainChrome
        settings.firstRun = .passed
        firstRun = .passed

        persistSettings()
        append(
            level: .info,
            message: chromeChanged
                ? "первоначальная настройка применена, приложение перезапускается ради оформления"
                : "первоначальная настройка применена"
        )
        return chromeChanged
    }

    /// Рабочее место: две ветки экрана 2 — ключ и «Вручную».
    private func applyFirstRunWorkplace(flow: FirstRunFlow) {
        switch flow.route {
        case .activationKey:
            guard let package = flow.openedPackage else { return }
            applyActivation(package)

        case .manual:
            let host = flow.host.trimmingCharacters(in: .whitespacesAndNewlines)
            // Домен равен адресу сервера, транспорт — умолчание. Площадка
            // остаётся `.automatic`: стучать или нет решает сам адрес
            // (`PortKnockSequence.isInternal`), и спрашивать об этом того, кто
            // только что вписал адрес, значило бы спрашивать дважды об одном.
            let profile = SIPProfile(
                account: SIPAccount(
                    username: flow.trimmedNumber,
                    displayName: "",
                    domain: host,
                    transport: .udp,
                    registrationExpires: 300
                ),
                password: flow.password,
                site: .automatic
            )
            settings.profiles = SIPProfileList(profiles: [profile])
        }
    }

    /// Применяет пакет активации (M9, работа 3).
    ///
    /// Порядок здесь важен: сперва учётная запись, потом управляемые поля,
    /// потом память о панели. Обратный порядок оставил бы `isServerManaged`
    /// посчитанным по старому режиму — наложение читает его из `panel`, а тот
    /// должен быть уже новым.
    func applyActivation(_ package: ActivationPackage) {
        // Номер и пароль ложатся **в существующий профиль**, а не рядом с ним.
        // `SIPProfileList` на свежей машине уже держит один пустой профиль —
        // ровно тот, из-за которого этап 9 и понадобился, — и заведение второго
        // оставляло бы в списке «без номера» плюс настроенный. Тот же урок, что
        // и у предустановочной ветки, найденный живым прогоном 17 августа 2026.
        settings.profiles.active.account.username = package.number
        settings.profiles.active.account.authUsername = nil
        settings.profiles.active.password = package.sipPassword

        // Панель машина слушает с первой же минуты: ключ и означает «этим
        // рабочим местом управляют отсюда».
        settings.panel.installationID = package.installationID
        settings.panel.channelKey = package.channelKey
        settings.panel.presetID = package.preset.id
        settings.panel.presetName = package.preset.name
        settings.panel.appliedRevision = package.preset.revision
        settings.panel.appliedAt = Date()
        settings.panel.mode = .managed

        // Управляемые поля — той же дорогой, что и файл предустановок: правило
        // «отсутствующее поле означает «панель им не управляет»» должно быть
        // одно на оба пути, а не два похожих.
        let addressesBefore = settings.siteAddresses
        settings.apply(ManagedFields.parse(package.preset.settings))

        // Адрес АТС профиля от пары адресов сам не следует — см.
        // `alignProfileAddress`. Без этой строки машина встаёт с номером и
        // паролем, но с пустым доменом: регистрироваться некуда.
        alignProfileAddress(previous: addressesBefore)

        // Административного пароля в пакете больше нет. Он стал полем
        // предустановки и приезжает отдельным помашинным объектом — первым же
        // заходом на канал, сразу после активации. Держать его ещё и в пакете
        // значило бы завести второй источник одного факта: пакет выдаётся один
        // раз, а пароль меняют когда угодно после.

        append(level: .info, message: "рабочее место поднято ключом: "
            + "\(package.employee), номер \(package.number), "
            + "предустановка «\(package.preset.name)» ревизия \(package.preset.revision)")
    }

    /// Перезапуск ради корпуса — после того, как всё уже записано.
    ///
    /// Отдельным методом, а не строкой внутри `completeFirstRun`: тот отвечает
    /// на «что применить», а этот на «чем закончить», и вызывающая сторона
    /// выбирает между перезапуском и открытием панели.
    func relaunchAfterFirstRun() {
        NSApp.sendAction(#selector(AppDelegate.relaunchApplication(_:)), to: nil, from: nil)
    }
}
