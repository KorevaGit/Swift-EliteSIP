import Compat
import Foundation

/// Договорённость об обновлении сессии, RFC 4028.
///
/// Нужна против «зависших» разговоров: если одна сторона исчезла, не прислав
/// BYE — упало питание, оборвался VPN, — вторая иначе держит линию, порты RTP и
/// строку в CDR до бесконечности. Таймер даёт обеим сторонам общий срок, после
/// которого разговор считается мёртвым, если его никто не подтвердил.
///
/// Боевой Asterisk настроен `Session Timers: Accept` — сам он таймер не
/// предлагает, но принимает предложенный и подтверждает своё участие. Значит
/// всё начинается с нас: не предложим — таймера не будет вовсе.
public struct SIPSessionTimer: Sendable, Hashable {

    /// Кто обязан обновлять сессию.
    ///
    /// `uac` — тот, кто позвонил, `uas` — тот, кому позвонили. Это роли в
    /// исходном INVITE, и они не меняются на протяжении диалога, как бы потом
    /// ни ходили повторные INVITE.
    public enum Refresher: String, Sendable, Hashable {
        case uac
        case uas
    }

    /// Срок сессии в секундах.
    public var expires: Int

    /// Кто обновляет.
    public var refresher: Refresher

    public init(expires: Int, refresher: Refresher) {
        self.expires = expires
        self.refresher = refresher
    }

    /// Через сколько обновлять, если обновляем мы.
    ///
    /// Половина срока по RFC 4028 §10. Половина, а не «незадолго до конца»,
    /// именно затем, чтобы одно потерянное обновление не обрывало разговор:
    /// второй заход успевает пройти до истечения.
    public var refreshAfter: Interval {
        .seconds(max(expires / 2, 1))
    }

    /// Через сколько считать сессию мёртвой, если обновляет собеседник.
    ///
    /// Полный срок: собеседник обязан был прислать обновление на середине, и к
    /// концу срока у него был ещё один шанс. Раньше времени рвать разговор
    /// нельзя — это была бы наша ошибка, а не его.
    public var expireAfter: Interval {
        .seconds(max(expires, 2))
    }

    // MARK: - Заголовок

    /// Значение заголовка `Session-Expires`.
    public var headerValue: String {
        "\(expires);refresher=\(refresher.rawValue)"
    }

    /// Разбирает `Session-Expires: 1800;refresher=uas`.
    ///
    /// Без параметра `refresher` возвращает `nil` для роли — сторона, которая
    /// его не прислала, ничего о ролях не сказала, и додумывать за неё нельзя:
    /// ошибка здесь означает, что обновлять не будет никто либо будут оба.
    public static func parse(_ value: String) -> (expires: Int, refresher: Refresher?)? {
        let parts = value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard let head = parts.first,
              let expires = Int(head.trimmedSIP),
              expires > 0
        else { return nil }

        guard parts.count > 1 else { return (expires, nil) }

        let refresher = SIPLexer.parseParameters(parts[1])
            .first { $0.name.lowercased() == "refresher" }
            .flatMap { $0.value.map { Refresher(rawValue: $0.lowercased()) } } ?? nil

        return (expires, refresher)
    }
}

/// Что предлагать и что считать допустимым.
///
/// Значения совпадают с боевыми (`Session Expires: 1800`, `Min-SE: 90`) не ради
/// подражания, а потому что несовпадение стоило бы лишнего круга: предложи мы
/// меньше боевого `Min-SE`, сервер ответил бы 422, и звонок начинался бы с
/// заведомо отклонённого запроса.
public struct SIPSessionTimerPolicy: Sendable, Hashable {

    /// Предлагаемый срок сессии в секундах.
    public var expires: Int

    /// Наименьший срок, который мы согласны принять.
    public var minimumExpires: Int

    /// Включено ли вообще.
    ///
    /// Выключение оставлено осознанно: таймер сессии — единственный механизм в
    /// клиенте, который сам кладёт трубку. Если на чужом сервере он поведёт
    /// себя не так, это должно чиниться настройкой, а не пересборкой.
    public var isEnabled: Bool

    public init(expires: Int = 1800, minimumExpires: Int = 90, isEnabled: Bool = true) {
        self.expires = expires
        self.minimumExpires = minimumExpires
        self.isEnabled = isEnabled
    }

    /// Роль, которую мы предпочитаем отдать собеседнику.
    ///
    /// Обновлять просим сервер, а сами по возможности остаёмся стороной,
    /// которая только следит. Причина в цене ошибки: если ошибётся наш таймер
    /// обновления, мы уроним живой разговор своими руками. Если не обновит
    /// сервер — разговор и правда мёртв, и класть трубку правильно. Боевой
    /// Asterisk в роли UAS обновляет сам (`Session Refresher: uas`), так что
    /// на исходящих звонках это совпадает с его собственным выбором.
    public static let preferredPeerRefresher = SIPSessionTimer.Refresher.uas

    /// Договорённость по ответу сервера на наш INVITE.
    ///
    /// `nil` означает «таймера нет»: сервер либо промолчал про `Session-Expires`,
    /// либо прислал негодное значение. Молчание — законный ответ (RFC 4028 §7.2),
    /// и обращаться с ним надо именно как с отсутствием договорённости, а не
    /// как с подразумеваемым согласием: иначе мы завели бы таймер, о котором
    /// вторая сторона не знает, и положили бы трубку посреди разговора.
    public func negotiated(fromResponse headers: SIPHeaders) -> SIPSessionTimer? {
        guard isEnabled,
              let raw = headers[SIPSessionTimerHeader.sessionExpires],
              let parsed = SIPSessionTimer.parse(raw)
        else { return nil }

        // Роль по умолчанию — uas: так предписывает RFC 4028 §7.2 для ответа
        // без параметра, и так же удобнее нам (обновляет сервер).
        return SIPSessionTimer(expires: parsed.expires, refresher: parsed.refresher ?? .uas)
    }

    /// Договорённость для ответа на чужой INVITE.
    ///
    /// Возвращает `nil`, когда звонящий про таймер не заговаривал: навязывать
    /// его тому, кто о нём не просил, нельзя — он не станет ни обновлять, ни
    /// следить, а трубку в срок положим мы.
    public func negotiated(forIncoming headers: SIPHeaders) -> SIPSessionTimer? {
        guard isEnabled,
              let raw = headers[SIPSessionTimerHeader.sessionExpires],
              let parsed = SIPSessionTimer.parse(raw)
        else { return nil }

        // Срок берём предложенный, но не короче того, на что согласны сами.
        // Звонящий обязан был учесть наш Min-SE только если знал его, а на
        // первом INVITE он его не знал.
        let expires = max(parsed.expires, minimumExpires)

        // Обновляющим назначаем звонящего. Выбор за нами (RFC 4028 §8.2: UAS
        // решает), и он тот же, что на исходящих: следить дешевле, чем
        // обновлять, а цена нашей ошибки — брошенный живой разговор.
        return SIPSessionTimer(expires: expires, refresher: .uac)
    }
}

/// Имена заголовков RFC 4028.
///
/// Отдельным типом, а не в `SIPHeaderName`: там перечислены заголовки ядра
/// RFC 3261, и дописывание в тот список расширений по одному быстро превращает
/// его в свалку. Каноническое написание обоих имён в `SIPHeaderName` уже есть.
public enum SIPSessionTimerHeader {
    public static let sessionExpires = "Session-Expires"
    public static let minSE = "Min-SE"

    /// Значение для `Supported`, которым объявляется поддержка.
    public static let optionTag = "timer"
}
