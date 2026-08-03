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
        if !before.isConferenceCommandSent, after.isConferenceCommandSent {
            historyStore.markConference(id)
        }
    }

    /// Закрывает запись линии.
    ///
    /// Причина — та же строка, что видел оператор в подписи под кнопкой.
    /// Расхождение здесь означало бы, что человек помнит одно, а история
    /// показывает другое, и верить после этого будут памяти.
    func finishHistory(lineID: String, reason: String) {
        guard let historyStore, let id = historyRecordIDs.removeValue(forKey: lineID) else { return }
        historyStore.finish(id, reason: reason)
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
            return
        }
        // Записи только что закрытого звонка ждём: список открывают сразу
        // после разговора, и увидеть в нём «идёт» вместо длительности значит
        // решить, что история сломана.
        historyStore.flush()
        historyRecords = historyStore.records(matching: historyFilter, limit: Self.historyPageSize)
        historyTotalCount = historyStore.count(matching: historyFilter)
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
}
