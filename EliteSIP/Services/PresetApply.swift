import CallGuard
import CommonCrypto
import Foundation
import PanelLink
import SIPCore

/// Наложение управляемых полей панели на настройки машины.
///
/// Разбор живёт в пакете `PanelLink` — он проверяется тестами, — а здесь только
/// перекладывание: из необязательных полей в настоящие. Перекладывание нарочно
/// многословное, по строке на поле. Это не небрежность: каждая строка читается
/// и проверяется глазами по отдельности, а всякая попытка сократить их в цикл
/// или в `KeyPath`-таблицу превращает двадцать шесть отдельных решений в одно
/// общее — и ошибка в нём уезжает на все рабочие места разом.
///
/// **Правило одно на весь файл: `nil` — это «панель этим не управляет».**
/// Не «ноль», не «пусто», не «выключено». Машина сохраняет своё текущее
/// значение, и записывается оно тем, что присвоения просто не происходит.
/// Правило принято в M8 и стоит там же: предустановка, написанная ради
/// макросов, иначе молча стёрла бы политику защиты.
extension AppSettings {

    /// Накладывает управляемые поля, оставляя нетронутым всё, чем панель не
    /// управляет.
    mutating func apply(_ fields: ManagedFields) {
        applyDTMF(fields.dtmf)
        applyIncomingCall(fields.incomingCall)
        applyConference(fields.conference)
        applyPortKnock(fields.portKnock)
        applySiteAddresses(fields.siteAddresses)
        applyTLSTrust(fields.acceptsAnyTLSCertificate)
        applyTransport(fields.transport)

        // Признак «этим управляет сервер» выводится из режима машины, а не из
        // файла, и ставится здесь — в одном месте на все управляемые поля.
        //
        // Поле заведено в M7c как «место под вариант 1» и до сих пор всегда
        // было false. Теперь оно наконец получает смысл: машина под
        // предустановкой показывает управляемые ползунки, но не даёт их трогать.
        incomingCall.isServerManaged = panel.isManaged
    }

    // MARK: - Клавиши

    private mutating func applyDTMF(_ incoming: ManagedFields.DTMF?) {
        guard let incoming else { return }

        if let value = incoming.toneMilliseconds { dtmf.toneMilliseconds = value }
        if let value = incoming.gapMilliseconds { dtmf.gapMilliseconds = value }
        if let value = incoming.pauseMilliseconds { dtmf.pauseMilliseconds = value }
        if let value = incoming.macroColumns { dtmf.macroColumns = value }
        if let value = incoming.macroHeight { dtmf.macroHeight = value }
        if let value = incoming.macroHeightIsManual { dtmf.macroHeightIsManual = value }

        if let macros = incoming.macros {
            // Список заменяется целиком, а не сливается по одной клавише.
            //
            // Слияние выглядело бы бережнее и было бы неверно: раскладку задаёт
            // администратор целиком, и удалённая им клавиша обязана исчезнуть.
            // Слияние оставило бы её на месте навсегда — ровно ту клавишу,
            // которую убрали, потому что она набирала не тот код.
            dtmf.macros = macros.map { macro in
                var result = AppSettings.DTMFSettings.Macro()
                result.id = Self.identity(macro.id)
                if let title = macro.title { result.title = title }
                if let sequence = macro.sequence { result.sequence = sequence }
                if let transfers = macro.transfersCall { result.transfersCall = transfers }
                return result
            }
        }
    }

    // MARK: - Приём вызова

    private mutating func applyIncomingCall(_ incoming: ManagedFields.CallGuard?) {
        guard let incoming else { return }

        if let value = incoming.isEnabled { incomingCall.isEnabled = value }
        if let value = incoming.isRandomPositionEnabled { incomingCall.isRandomPositionEnabled = value }
        if let value = incoming.tunesRandomnessByHand { incomingCall.tunesRandomnessByHand = value }
        if let value = incoming.minimumTravel { incomingCall.minimumTravel = value }
        if let value = incoming.screenMargin { incomingCall.screenMargin = value }
        if let value = incoming.targetCount { incomingCall.targetCount = value }
        if let value = incoming.requiresCursorMovement { incomingCall.requiresCursorMovement = value }
        if let value = incoming.tunesLivenessByHand { incomingCall.tunesLivenessByHand = value }
        if let value = incoming.requiredCursorTravel { incomingCall.requiredCursorTravel = value }
        if let value = incoming.requiredCursorSamples { incomingCall.requiredCursorSamples = value }
        if let value = incoming.rejectsSyntheticEvents { incomingCall.rejectsSyntheticEvents = value }

        // `isServerManaged` не трогается ни при каких обстоятельствах: его
        // выводит режим машины, а не файл. Приехавшее полем оно означало бы два
        // источника одного факта — поэтому его нет и в самом контракте.

        // Приведение к своим границам после наложения, а не до: панель проверяет
        // те же пределы у себя, но её проверка и наши границы могут разойтись
        // на новой сборке, и последнее слово должно оставаться за машиной.
        incomingCall = incomingCall.normalized
    }

    // MARK: - Конференция

    private mutating func applyConference(_ incoming: ManagedFields.Conference?) {
        guard let incoming else { return }

        if let value = incoming.featureCode { conference.featureCode = value }
        if let value = incoming.roomExtension { conference.roomExtension = value }
    }

    // MARK: - Стук

    private mutating func applyPortKnock(_ incoming: ManagedFields.PortKnock?) {
        guard let incoming else { return }

        if let value = incoming.spacingSeconds { portKnock.spacingSeconds = value }
        if let value = incoming.repeatIntervalSeconds { portKnock.repeatIntervalSeconds = value }

        if let steps = incoming.steps {
            // Пустой список — это «стучать нечем», то есть выключенный стук, а
            // не отсутствие управления. Отличает их то же самое: отсутствие
            // ключа даёт `nil` и сюда не доходит.
            portKnock.steps = steps.map { step in
                PortKnockStep(
                    host: step.host ?? "",
                    payloadBytes: step.payloadBytes ?? 0,
                    count: step.count ?? 0
                )
            }
        }
    }

    // MARK: - Адреса

    private mutating func applySiteAddresses(_ incoming: ManagedFields.SiteAddresses?) {
        guard let incoming else { return }

        // Самое опасное, что возит эта линия: разъехавшийся адрес означает
        // телефон, который не звонит на всех рабочих местах разом. Поэтому
        // половины накладываются порознь — панель может управлять одной и не
        // управлять другой.
        if let value = incoming.office { siteAddresses.office = value }
        if let value = incoming.remote { siteAddresses.remote = value }
    }

    // MARK: - Доверие сертификату

    /// Единственное поле, которое живёт не в `AppSettings`, а в активном
    /// профиле: доверие к сертификату — свойство сервера, а не приложения.
    /// Здесь оно накладывается через готовый прокси, который это и скрывает.
    ///
    /// Панель управляет им ровно затем, чтобы держать его **выключенным**:
    /// аудит M7b нашёл включённое ради лаборатории значение, молча оставшееся
    /// включённым на боевом профиле после переключения.
    private mutating func applyTLSTrust(_ incoming: Bool?) {
        guard let incoming else { return }
        acceptsAnyTLSCertificate = incoming
    }

    /// Протокол связи с АТС активного профиля.
    ///
    /// Незнакомая строка не применяется вовсе — это то же правило, что и у
    /// `nil`, и по той же причине. Панель проверяет значение у себя и присылает
    /// одно из двух, но разбор здесь обязан быть терпимым: приехавшее из
    /// будущего `ws` не должно уводить рабочее место на UDP молча.
    ///
    /// Порт не трогается. Свой, вписанный руками, остаётся своим; пустой так и
    /// остаётся пустым, и тогда `SIPAccount` берёт умолчание нового транспорта
    /// по RFC 3261 — 5060 для UDP, 5061 для TLS.
    private mutating func applyTransport(_ incoming: String?) {
        guard let incoming, let transport = SIPTransport(name: incoming) else { return }
        profiles.active.account.transport = transport
    }

    // MARK: - Опознание строк

    /// Идентификатор клавиши или очереди из того, что прислала панель.
    ///
    /// Панель выдаёт настоящие UUID и проверяет это у себя, поэтому обычная
    /// дорога — прямое разбор. Запасная нужна на случай, когда прислали не
    /// UUID: **выводим устойчивый идентификатор из строки**, а не заводим
    /// новый. Новый на каждом наложении означал бы, что клавиша меняет личность
    /// каждые полчаса, — а по личности её отличают и настройки, и всё, что на
    /// них завязано.
    static func identity(_ raw: String?) -> UUID {
        guard let raw, !raw.isEmpty else { return UUID() }
        if let parsed = UUID(uuidString: raw) { return parsed }

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        Array(raw.utf8).withUnsafeBufferPointer { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &digest)
        }
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3],
                           digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11],
                           digest[12], digest[13], digest[14], digest[15]))
    }
}
