import AdminAccess
import AppKit
import Foundation
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
        case .preset:
            guard let preset = flow.selectedPreset else { return nil }
            var account = preset.snapshot(site: flow.site).profiles.active.account
            account.username = flow.trimmedNumber
            account.authUsername = nil
            return (account, flow.password, flow.site)

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

        case .configFile:
            return nil
        }
    }

    /// Применяет всё, что набрано в мастере.
    ///
    /// Порядок здесь — не вкусовщина, а единственный работающий:
    ///
    /// 1. настройки рабочего места (предустановка, ручной ввод или слепок);
    /// 2. административные учётные данные из конфига;
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

        // Пароль всегда из конфига, а не из файла и не из снимка: слепок с
        // машины, где его правили руками, увёз бы её пароль на новую — и та
        // встала бы с паролем, которого нет ни у кого.
        if let secrets = Provisioning.secrets {
            do {
                settings.admin.credential = try secrets.credential()
                settings.admin.management = .local
            } catch {
                // Не молчим: без учётных данных машина остаётся с «Управлением»,
                // открытым всякому, а выглядит настроенной.
                append(level: .error, message: "не удалось применить административный пароль: \(error)")
            }
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

    /// Рабочее место: три ветки экрана 2.
    private func applyFirstRunWorkplace(flow: FirstRunFlow) {
        switch flow.route {
        case .preset:
            guard let preset = flow.selectedPreset else { return }
            // Площадка выбирает и признак стука, и адрес из пары — снимок
            // собирается уже под неё.
            //
            // Применяется **к существующему профилю**, а не рядом с ним, и это
            // не мелочь: `SIPProfileList` на свежей машине уже держит один
            // пустой профиль — ровно тот, из-за которого этап и понадобился, —
            // и `to: nil` заводил второй. В списке профилей после мастера
            // оставалось два: «без номера» и настроенный. Нашёл живой прогон
            // 17 августа 2026.
            applyPreset(
                preset.settingsPreset(site: flow.site),
                number: flow.trimmedNumber,
                password: flow.password,
                to: settings.profiles.activeID
            )

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

        case .configFile:
            guard let config = flow.loadedConfig else { return }
            // Слепок уже очищен от машинного и от блока доступа при чтении
            // (`EliteSIPDocument`). Предустановки машины при этом сохраняются:
            // они свойство этой машины, а не приехавшего файла.
            let keptPresets = settings.presets
            settings = config
            settings.presets = keptPresets
        }
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
