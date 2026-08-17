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

    /// Применяет всё, что набрано в мастере, и перезапускает приложение.
    ///
    /// Порядок здесь — не вкусовщина, а единственный работающий:
    ///
    /// 1. настройки рабочего места (предустановка, ручной ввод или слепок);
    /// 2. административные учётные данные из конфига;
    /// 3. тема и стекло — поверх всего, что приехало из файла или снимка;
    /// 4. признак `awaitingFinale` и язык;
    /// 5. запись на диск;
    /// 6. перезапуск.
    ///
    /// Перезапуск последним и обязателен: язык берётся при старте процесса
    /// (`AppleLanguages`), корпус — при сборке окон, и на лету ни то ни другое не
    /// применяется. На первом запуске он бесплатен — ни регистрации, ни разговора
    /// ещё нет, и все предупреждения из «Настроек» здесь не действуют.
    func completeFirstRun(flow: FirstRunFlow) {
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
        settings.firstRun = .awaitingFinale
        firstRun = .awaitingFinale

        persistSettings()
        // До перезапуска и синхронно: новый процесс поднимается раньше, чем
        // завершается старый, и незаписанный выбор он просто не увидит.
        flow.language.apply()
        append(level: .info, message: "первоначальная настройка применена, приложение перезапускается")

        NSApp.sendAction(#selector(AppDelegate.relaunchApplication(_:)), to: nil, from: nil)
    }

    /// Рабочее место: три ветки экрана 2.
    private func applyFirstRunWorkplace(flow: FirstRunFlow) {
        switch flow.route {
        case .preset:
            guard let preset = flow.selectedPreset else { return }
            // Площадка выбирает и признак стука, и адрес из пары — снимок
            // собирается уже под неё.
            applyPreset(
                preset.settingsPreset(site: flow.site),
                number: flow.trimmedNumber,
                password: flow.password,
                to: nil
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

    /// Финальный экран: закрыть мастер и открыть панель.
    func finishFirstRun() {
        settings.firstRun = .passed
        firstRun = .passed
        persistSettings()
        append(level: .info, message: "первоначальная настройка закончена")
    }
}
