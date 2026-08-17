import AppKit
import CallHistory
import Foundation

/// Обслуживание машины: выгрузка файлов, чистка и сброс.
///
/// Собрано в отдельный раздел, потому что «Диагностика» иначе становится
/// местом, где рядом стоят «Скопировать журнал» и «Стереть машину».
///
/// Общее правило раздела: **действия здесь немедленные, а не черновиковые.**
/// Файл, стёртый по кнопке, «Отменой» не возвращается, и делать вид, что
/// возвращается, нельзя. Единственное исключение — загрузка чужого
/// `settings.json`: она ложится в тот же черновик, что и всё остальное окно, и
/// откатывается вместе с ним.
extension AppModel {

    // MARK: - Выгрузка

    /// Пишет настройки в выбранный файл.
    ///
    /// Выгружается то, что видно в окне, включая несохранённое, — а не то, что
    /// лежит на диске. Иначе администратор, настроивший рабочее место и
    /// выгрузивший образец, унёс бы на флешке состояние «до».
    func exportSettings(to destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: destination)
        append(level: .info, message: "настройки выгружены в файл")
    }

    /// Кладёт журнал рядом с выбранным местом одним архивом.
    ///
    /// Тем же `SupportArchive`, что и «Собрать архив для поддержки»: второй
    /// способ упаковать журнал означал бы, что однажды в поддержку уедет не то,
    /// что мы думаем.
    func exportLog(to destination: URL) throws {
        _ = try makeSupportArchive(to: destination)
        append(level: .info, message: "журнал выгружен в файл")
    }

    // MARK: - Чистка

    /// Стирает файлы журнала.
    ///
    /// Строку об этом писать некуда — она ушла бы в тот самый журнал, который
    /// только что стёрли, и первой же записью в новом файле было бы «журнал
    /// очищен». Это не след, а шум: пустой журнал и так очевиден.
    func clearLogFile() {
        logFile?.removeAll()
        clearLog()
    }

    /// Стирает историю звонков целиком.
    ///
    /// Отменяет решение этапа 4 («удаления руками нет ни у кого»), и отменяет
    /// осознанно: довод про свидетельство при разборе жалобы остаётся верным
    /// для оператора — он до этой кнопки не дотягивается, — но перестаёт
    /// работать там, где машину передают другому сотруднику.
    ///
    /// Возражение снимается следом: стирается всё целиком, не выборочно, и в
    /// журнал уходит число. Стереть можно, бесследно — нельзя.
    @discardableResult
    func clearHistory() -> Int {
        guard let historyStore else { return 0 }
        historyStore.flush()
        let removed = historyStore.deleteAll()
        append(level: .warning, message: "история очищена, записей — \(removed)")
        reloadHistory()
        refreshHistoryDays()
        return removed
    }

    // MARK: - Полный сброс

    /// Можно ли сбрасывать прямо сейчас.
    ///
    /// В разговоре нельзя — по той же причине, по которой нельзя менять
    /// профиль: сброс снимает регистрацию и закрывает диалоги, то есть кладёт
    /// трубку за оператора.
    var canResetMachine: Bool { lines.isEmpty }

    /// Возвращает машину в состояние сразу после установки: настройки, история
    /// и журнал.
    ///
    /// **Ловушка, ради которой порядок именно такой.** Сброс стирает журнал, то
    /// есть уносит с собой весь административный след — включая строку об
    /// очищенной истории, записанную минуту назад. Поэтому своя строка пишется
    /// последней, уже в новый файл: `LogFile.removeAll` заново открывает
    /// журнал, и запись после неё попадает туда, а не в удалённый.
    func resetMachine() {
        guard canResetMachine else { return }

        // Черновик закрывается до всего остального: иначе `isHoldingSettingsWrites`
        // придержал бы запись свежих умолчаний, а снимок вернул бы стёртое
        // при первом же «Отменить».
        administrationSnapshot = nil
        isHoldingSettingsWrites = false
        pendingAdminPassword = nil
        pendingAdminPasswordRemoval = false

        historyStore?.flush()
        historyStore?.deleteAll()
        historyStore = nil
        historyRecords = []

        try? FileManager.default.removeItem(at: AppSettings.CallHistorySettings.fileURL)
        try? FileManager.default.removeItem(at: SettingsStore.fileURL)

        // Пароль администратора живёт в настройках, и умолчание его не
        // содержит: после сброса машина открыта всем, как свежеустановленная.
        // `restore` заодно закрывает режим — тем же путём, что и запуск.
        settings = .default
        // Сброшенная машина требует мастер заново — иначе она остаётся ровно в
        // том состоянии, ради лечения которого мастер и заведён: пустой профиль
        // и настройки, открытые всякому. Признак пишется в настройки, а не
        // держится в памяти: файл сейчас же появится снова (умолчания уходят на
        // диск наблюдателем `settings`), и по отсутствию файла мастер уже не
        // позвать.
        //
        // Следствие принято сознательно: сбросить машину и уйти нельзя — до
        // нового прохода мастера приложение непроходимо, а пропуск знает только
        // техподдержка.
        settings.firstRun = .needed
        firstRun = .needed
        adminAccess.restore(credential: nil, management: .local)

        logFile?.removeAll()
        append(level: .warning, message: "машина сброшена: настройки, история и журнал стёрты")

        openHistoryIfNeeded()
        refreshHistoryDays()

        // Мастер зовётся здесь же, а не только при запуске.
        //
        // Признака `.needed` самого по себе не хватает: окно первоначальной
        // настройки открывалось лишь в `applicationDidFinishLaunching`, и сброс
        // на живой машине оставлял её с пустыми настройками, открытым
        // «Управлением» и без единого слова о том, что делать дальше. Ровно то
        // состояние, ради лечения которого этап 9 и затевался, — и получить его
        // можно было одной кнопкой в «Обслуживании».
        //
        // Через цепочку ответчиков, как перезапуск: окнами владеет делегат
        // приложения, а модель о них не знает и знать не должна. Асинхронно —
        // сброс вызван кнопкой из окна, которое делегат сейчас закроет, и
        // закрывать его посреди его же обработчика незачем.
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(AppDelegate.showFirstRunAfterReset(_:)), to: nil, from: nil)
        }
    }

    // MARK: - Загрузка чужого файла

    /// Что помешало принять файл.
    enum SettingsImportFailure: Error {

        /// Файл от более новой версии приложения.
        ///
        /// Отдельным отказом, а не терпимым чтением: декодер настроек
        /// намеренно терпелив к незнакомым полям, и без этой проверки файл от
        /// следующей версии прочитался бы молча, потеряв всё, чего эта сборка
        /// не знает. Потеря обнаружилась бы уже после «Сохранить».
        case newerSchema(Int)

        /// Файл не разобрался вовсе.
        case unreadable

        var title: String {
            switch self {
            case .newerSchema(let version):
                return String(
                    format: NSLocalizedString("""
                        Файл от более новой версии приложения (схема %1$lld, \
                        эта сборка знает %2$lld). \
                        Часть настроек в ней была бы потеряна.
                        """, comment: "загрузка настроек из файла"),
                    version,
                    AppSettings.currentSchemaVersion
                )
            case .unreadable:
                return NSLocalizedString(
                    "Файл не похож на настройки EliteSIP.",
                    comment: "загрузка настроек из файла"
                )
            }
        }
    }

    /// Кладёт чужой `settings.json` в черновик.
    ///
    /// **В черновик, а не на диск.** Окно заполняется значениями из файла, но
    /// до «Сохранить» не записывается ничего, и «Отменить» возвращает как было.
    /// Иначе в окне, которое всё копит, появилась бы одна кнопка, которая
    /// применяет сразу, — и порядок работы перестал бы читаться.
    ///
    /// Файл берётся целиком, включая пароль SIP и административный ящик: ради
    /// переноса рабочего места всё и затевалось. Административный пароль при
    /// этом уходит в `pendingAdminPassword`-механику через `settings.admin`, а
    /// не мимо неё, — то есть «Отменить» возвращает и его.
    func importSettings(from source: URL) throws {
        let data = try Data(contentsOf: source)

        struct Header: Decodable { var schemaVersion: Int? }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
            throw SettingsImportFailure.unreadable
        }
        if let version = header.schemaVersion, version > AppSettings.currentSchemaVersion {
            throw SettingsImportFailure.newerSchema(version)
        }
        guard let imported = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            throw SettingsImportFailure.unreadable
        }

        settings = imported
        append(level: .warning, message: "настройки загружены из файла, применение — по «Сохранить»")
    }

    /// Останется ли машина без пароля, если принять этот файл.
    ///
    /// Спрашивается до применения: предупреждение обязано назвать последствие
    /// прямо, а «пароль будет заменён» его не называет.
    func importWouldRemoveAdminPassword(_ source: URL) -> Bool {
        guard let data = try? Data(contentsOf: source),
            let imported = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return false }
        return imported.admin.credential == nil
    }
}
