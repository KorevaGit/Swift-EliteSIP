import CallHistory
import Compat
import Foundation

/// Локальная история звонков со стороны приложения.
///
/// Пакет `CallHistory` умеет хранить и выбирать, но не знает ни про линии, ни
/// про профили. Здесь живёт перевод одного в другое: какая линия какой записи
/// соответствует, что считать началом и концом звонка и когда убирать
/// просроченное.
///
/// **Запись обязана быть незаметной для звонка.** Всё, что делает история, —
/// это `INSERT` и три `UPDATE` на разговор, и все они уходят на очередь пакета.
/// Ни одно действие здесь не имеет права ни задержать набор, ни тем более
/// отменить его: софтфон, не позвонивший из-за собственной истории, — исход
/// хуже, чем софтфон без истории.
extension AppModel {

    // MARK: - Хранилище

    /// Открывает историю по настройкам и пишет в журнал, чем это кончилось.
    ///
    /// Молчать здесь нельзя. История, которая ничего не помнит, выглядит на
    /// рабочем месте точно так же, как история, в которой просто не было
    /// звонков, — и разбирать это потом будет не по чему.
    func openHistoryIfNeeded() {
        guard settings.history.isEnabled else {
            historyStore = nil
            historyRecords = []
            return
        }

        let store = CallHistoryStore(settings: settings.history.storage)
        historyStore = store

        switch store.openOutcome {
        case .ready:
            append(
                level: .debug,
                message: "история звонков открыта, срок хранения \(settings.history.storage.maximumAgeInDays) дн."
            )
        case .replacedDamaged(let damaged):
            // Именно предупреждением и с именем файла: человек потерял историю
            // и имеет право знать, где лежит то, что от неё осталось.
            append(
                level: .warning,
                message: "история звонков была повреждена и отставлена в \(damaged.lastPathComponent); заведена новая"
            )
        case .unavailable(let reason):
            append(level: .error, message: "история звонков недоступна: \(reason)")
        }

        reloadHistory()
        refreshHistoryDays()
        startHistoryPruning()
    }

    /// Уборка по сроку раз в сутки.
    ///
    /// Открытия базы недостаточно: рабочее место неделями не перезагружают, а
    /// удаление персональных данных по сроку — обещание, которое не должно
    /// зависеть от того, когда оператор в последний раз выходил из программы.
    private func startHistoryPruning() {
        historyPruneTask?.cancel()
        historyPruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(.seconds(24 * 60 * 60))
                guard !Task.isCancelled, let self, let historyStore else { return }
                let removed = historyStore.prune()
                guard removed > 0 else { continue }
                // Удаление персональных данных по сроку — то, о чём в журнале
                // должна остаться строка.
                append(level: .info, message: "история: удалено записей по сроку — \(removed)")
                reloadHistory()
            }
        }
    }

    // MARK: - Запись по ходу звонка

    /// Заводит запись о начавшемся звонке и запоминает, какой линии она
    /// принадлежит.
    ///
    /// Вызывается в момент появления линии — на первом гудке и на входящем
    /// INVITE, а не по факту разговора. Незавершённый звонок в истории нужен:
    /// пропущенный входящий — это как раз запись без ответа и без конца.
    func beginHistory(
        lineID: String,
        direction: CallRecord.Direction,
        number: String,
        sipLogin: String? = nil,
        displayName: String? = nil,
        role: CallRecord.Role = .primary
    ) {
        guard let historyStore else { return }
        let record = CallRecord(
            callID: lineID,
            direction: direction,
            role: role,
            number: number,
            sipLogin: sipLogin,
            displayName: displayName,
            profileID: settings.profiles.active.id,
            // Метка копируется в запись, а не берётся из профиля при показе:
            // профиль переименуют или удалят, а история обязана остаться
            // читаемой. Правило «пустая метка значит номер» берётся у самого
            // профиля, а не повторяется здесь — иначе два места однажды
            // разойдутся.
            profileLabel: settings.profiles.active.title
        )
        historyRecordIDs[lineID] = record.id
        historyStore.begin(record)
    }

    /// Замечает перемены на линии и дописывает их в историю.
    ///
    /// Вызывается из единственного места, где линия вообще меняется, —
    /// `mutate`. Так же, как маскирование секретов стоит на единственном пути в
    /// файл журнала: второй путь, забывший отметить ответ, тут завести нельзя.
    func noteHistory(before: CallLine, after: CallLine) {
        guard let historyStore, let id = historyRecordIDs[after.id] else { return }

        if before.phase != .active, after.phase == .active {
            historyStore.markAnswered(id)
        }
        if !before.isTransferring, after.isTransferring {
            historyStore.markTransferred(id)
        }
        // Перевод макросом — та же пометка, что и своим REFER.
        //
        // Разными их делать нельзя: для того, кто читает историю при разборе
        // жалобы, важно, что звонок увели, а не каким протоколом. Чем именно —
        // видно в журнале, там записан и код, и подпись клавиши.
        if !before.didSendTransferMacro, after.didSendTransferMacro {
            historyStore.markTransferred(id)
        }
        if !before.isConferenceCommandSent, after.isConferenceCommandSent {
            historyStore.markConference(id)
        }
    }

    /// Закрывает запись линии.
    ///
    /// Причина — та же строка, что видел оператор в подписи под кнопкой.
    /// Расхождение здесь означало бы, что человек помнит одно, а история
    /// показывает другое, и верить после этого будут памяти.
    ///
    /// Код исхода приходит отдельно от причины и только оттуда, где ответ
    /// сервера ещё разобран на части. Выводить его из самой причины нельзя:
    /// формулировку на панели однажды поменяют, и история молча начнёт писать
    /// «отказ» вместо «занято».
    func finishHistory(lineID: String, reason: String, outcome: CallRecord.Outcome? = nil) {
        guard let historyStore, let id = historyRecordIDs.removeValue(forKey: lineID) else { return }
        historyStore.finish(id, reason: reason, outcome: outcome)
        reloadHistory()
    }

    // MARK: - Список

    /// Перечитывает страницу истории под текущий фильтр.
    ///
    /// Страницей, а не целиком: приёмка требует, чтобы десять тысяч записей не
    /// замедляли открытие панели, и держать их все в памяти ради списка,
    /// который показывает два десятка строк, незачем.
    func reloadHistory() {
        guard let historyStore else {
            historyRecords = []
            historyTotalCount = 0
            historyTotalCountUnfiltered = 0
            return
        }
        // Записи только что закрытого звонка ждём: список открывают сразу
        // после разговора, и увидеть в нём «идёт» вместо длительности значит
        // решить, что история сломана.
        historyStore.flush()

        let scope = historyScope
        historyRecords = historyStore.records(
            matching: historyFilter, scope: scope, limit: Self.historyPageSize
        )
        historyTotalCount = historyStore.count(matching: historyFilter, scope: scope)

        // Второй счёт — только ради пустого состояния: оно обязано отличать
        // «под фильтр ничего не попало» от «звонков не было вовсе». Считается
        // без дня и без направления, то есть по всей истории профиля.
        let wholeProfile = CallHistoryStore.Scope(profileID: scope.profileID)
        historyTotalCountUnfiltered = historyFilter == .all && scope.day == nil
            ? historyTotalCount
            : historyStore.count(matching: .all, scope: wholeProfile)
    }

    /// Догружает следующую страницу, когда оператор долистал до низа.
    ///
    /// Без этого всё, что старше первых двухсот записей, было недостижимо ни
    /// одним действием: `OFFSET` в хранилище есть с M7d, но второй страницы в
    /// интерфейсе не существовало. У оператора колл-центра двести записей —
    /// это два-три дня.
    ///
    /// Повторный вызов на той же странице безвреден: выборка идёт от текущего
    /// числа показанных строк, и пока догрузка не пришла, смещение не меняется.
    func loadMoreHistory() {
        guard let historyStore, historyHasMore else { return }
        let next = historyStore.records(
            matching: historyFilter,
            scope: historyScope,
            limit: Self.historyPageSize,
            offset: historyRecords.count
        )
        guard !next.isEmpty else { return }

        // По идентификатору, а не слепым добавлением: между страницами мог
        // прийти новый звонок, и тогда граница страницы сдвигается — запись,
        // стоявшая двухсотой, приезжает во второй странице ещё раз. В списке
        // это выглядит как задвоившийся звонок.
        var seen = Set(historyRecords.map(\.id))
        historyRecords.append(contentsOf: next.filter { seen.insert($0.id).inserted })
    }

    /// Перечитывает дни, в которые были звонки, — под точки в календаре.
    func refreshHistoryDays() {
        guard let historyStore else {
            historyDaysWithCalls = []
            return
        }
        historyDaysWithCalls = historyStore.daysWithCalls(
            scope: CallHistoryStore.Scope(profileID: settings.profiles.activeID)
        )
    }

    /// Показывает историю другого профиля.
    ///
    /// Зовётся при смене профиля, а не только при открытии окна: граница
    /// жёсткая, и открытое окно, показывающее историю профиля, с которого уже
    /// ушли, — это ровно та дыра, ради закрытия которой границу и проводили.
    /// Выбранный день при этом сбрасывается: он был выбран по чужим точкам.
    func historyDidChangeProfile() {
        historySelectedDay = nil
        reloadHistory()
        refreshHistoryDays()
    }

    /// Сколько записей потеряет удаление этого профиля.
    ///
    /// Нужно до удаления, а не после: отменить его нельзя, и человек обязан
    /// увидеть число раньше, чем нажмёт.
    func historyCount(ofProfile id: UUID) -> Int {
        guard let historyStore else { return 0 }
        historyStore.flush()
        return historyStore.count(matching: .all, scope: CallHistoryStore.Scope(profileID: id))
    }

    /// Номера, которые приходили на эту машину, но в словаре очередей не
    /// названы.
    ///
    /// Подсказка для «Очередей», и она отвечает на настоящую нехватку: номера
    /// очередей знает Asterisk заказчика, а боевой сервер у нас на чтение.
    /// Вбитая с голоса ошибка в цифре не проявляется ничем — вызов просто
    /// остаётся без названия.
    ///
    /// **В словарь ничего не попадает само.** Список только предлагает; строку
    /// заводит нажатие, и название всё равно вписывает человек. Иначе словарь
    /// зарос бы номерами, пришедшими не из очереди.
    func unnamedIncomingNumbers() -> [NumberSighting] {
        guard let historyStore else { return [] }
        historyStore.flush()
        // Длина отсекает лидов: номер очереди на FreePBX короткий, номер
        // клиента — полный телефонный. Шесть цифр покрывают и трёхзначные
        // добавочные, и четырёхзначные очереди боевой АТС.
        return historyStore
            .incomingNumbers(maximumDigits: 6)
            .filter { settings.queues.title(forCallerNumber: $0.number) == nil }
    }

    /// Удаляет историю профилей, которых больше нет.
    ///
    /// Вызывается из `commitAdministration`, а не из `removeProfile`: окно
    /// «Управление» копит правки до «Сохранить», и удаление записей — то, что
    /// «Отменить» вернуть не может. Это второе такое место после уменьшения
    /// срока хранения, и оба исключения по одной причине.
    func deleteHistory(ofProfiles ids: [UUID]) {
        guard let historyStore, !ids.isEmpty else { return }
        for id in ids {
            let removed = historyStore.deleteHistory(ofProfile: id)
            guard removed > 0 else { continue }
            // Удаление персональных данных — то, о чём в журнале обязана
            // остаться строка, ровно как при уборке по сроку.
            append(level: .info, message: "история удалённого профиля стёрта: записей — \(removed)")
        }
        reloadHistory()
        refreshHistoryDays()
    }

    /// Повторный набор одним нажатием.
    ///
    /// Номер, а не отображаемое имя: имя приезжает из EliteDash и набирать его
    /// нечем. Пустой номер — не повод для звонка в никуда.
    func redial(_ record: CallRecord) {
        guard canPlaceCall, !record.number.isEmpty else { return }
        dialedNumber = record.number
        Task { await placeCall() }
    }

    /// Сколько строк показывает окно за раз.
    static var historyPageSize: Int { 200 }

    // MARK: - История набора

    /// Последние набранные номера, новые первыми, без повторов.
    ///
    /// Не то же самое, что окно истории: там записи со временем, именем и
    /// исходом, здесь — только номера и только исходящие. Перезвон по
    /// пропущенному живёт в окне, а это про другое — «наберу тот же номер
    /// ещё раз», когда линия была занята или ответили не там.
    ///
    /// Читается из хранилища при каждом обращении, а не кэшируется: список
    /// нужен в момент нажатия стрелки, то есть раз в минуты, а расходиться с
    /// правдой он не должен вовсе.
    private var recentDialedNumbers: [String] {
        // Хранилища может не быть вовсе — база не открылась, и об этом уже
        // сказано в журнале. Стрелка тогда просто ничего не делает: жаловаться
        // на это второй раз в момент набора незачем.
        guard let historyStore else { return [] }

        // Область та же, что у окна, и по той же причине: номер, которого
        // оператор не видит в истории, не имеет права всплыть у него в поле
        // набора. День сюда не входит — стрелки про «наберу тот же номер ещё
        // раз», а не про выбранную в окне дату.
        var seen = Set<String>()
        var numbers: [String] = []
        for record in historyStore.records(
            matching: .outgoing,
            scope: CallHistoryStore.Scope(profileID: settings.profiles.activeID),
            limit: Self.dialHistoryDepth * 4
        ) where !record.number.isEmpty {
            // Повторы схлопываются: набирали три раза подряд — в списке один
            // раз, иначе стрелка вверх трижды приведёт в одно и то же место.
            guard seen.insert(record.number).inserted else { continue }
            numbers.append(record.number)
            if numbers.count == Self.dialHistoryDepth { break }
        }
        return numbers
    }

    /// Сколько номеров держим под стрелками.
    ///
    /// Десять — потому что дальше десятого шага стрелкой никто не листает: за
    /// этим уже идут в окно истории, где есть имена и время.
    static var dialHistoryDepth: Int { 10 }

    /// Шаг по истории набора: `-1` — к более старым, `+1` — к более новым.
    ///
    /// Положение хранится в `dialHistoryIndex`, а не выводится из содержимого
    /// поля: два одинаковых номера в списке невозможны, но набранное вручную
    /// совпадение с историей сбивало бы отсчёт.
    func stepDialHistory(_ step: Int) {
        let numbers = recentDialedNumbers
        guard !numbers.isEmpty else { return }

        let next = (dialHistoryIndex ?? -1) + step
        guard next >= 0 else {
            // Вышли выше самого свежего — возвращаем поле в то состояние, в
            // котором оператор его оставил, а не в пустое: он мог набрать
            // половину номера и полезть в историю по ошибке.
            dialHistoryIndex = nil
            dialedNumber = dialHistoryDraft
            return
        }
        guard next < numbers.count else { return }

        // Первый шаг в историю запоминает набранное: иначе вернуться к нему
        // будет неоткуда.
        if dialHistoryIndex == nil { dialHistoryDraft = dialedNumber }
        dialHistoryIndex = next
        dialedNumber = numbers[next]
    }

    /// Сбрасывает положение в истории. Зовётся, когда номер поменяли руками:
    /// после правки поле перестаёт быть «пунктом истории».
    func resetDialHistoryPosition() {
        dialHistoryIndex = nil
        dialHistoryDraft = ""
    }
}
