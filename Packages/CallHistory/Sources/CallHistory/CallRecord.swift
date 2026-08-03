import Foundation

/// Одна строка истории звонков.
///
/// Запись заводится в момент, когда звонок начался, и дописывается по ходу:
/// ответ, перевод, конференция, завершение. Так она переживает принудительное
/// завершение приложения — а оно посреди разговора вполне реально, и «пишем в
/// конце» означало бы, что теряются ровно те звонки, после которых софтфон
/// упал.
///
/// Идентификатор свой, а не `rowid` из базы: он нужен вызывающему сразу, чтобы
/// потом дописать в ту же строку ответ и завершение, а ждать ответа от диска в
/// момент начала звонка нельзя. С `rowid` пришлось бы либо ждать вставки, либо
/// заводить второй ключ.
public struct CallRecord: Sendable, Identifiable, Equatable {

    public enum Direction: Int, Sendable, Hashable, CaseIterable {
        case incoming = 0
        case outgoing = 1
    }

    /// Основная линия или консультационная.
    ///
    /// То, что в плане названо «линия». Хранится смыслом, а не номером линии:
    /// сам номер — это локальный Call-ID, он уже лежит в `callID`, а человеку,
    /// который смотрит историю, важно другое — этот звонок он набрал сам или
    /// это была консультация посреди чужого разговора.
    public enum Role: Int, Sendable, Hashable {
        case primary = 0
        case consultation = 1
    }

    public let id: UUID

    /// Локальный SIP Call-ID. По нему звонок ищут в журнале приложения, когда
    /// история и журнал расходятся в показаниях.
    public var callID: String

    /// Идентификатор звонка со стороны сервера.
    ///
    /// Пустует до M9. Заведён сейчас, а не тогда, ровно ради того, чтобы в M9
    /// локальная запись склеилась с CDR из EliteDash, а не задвоилась: без
    /// общего ключа сопоставлять пришлось бы по времени и номеру, а это
    /// угадывание, которое ошибается на очереди и на переводах.
    public var serverCallID: String?

    public var direction: Direction
    public var role: Role

    /// Номер собеседника, как он пришёл. Не нормализуется и не маскируется:
    /// решение 30 июля 2026 — номера лидов пишутся как есть.
    public var number: String

    /// Техническое имя extension из FreePBX, если сервер его прислал.
    ///
    /// Отдельно от номера: на входящем из очереди это разные вещи, и по логину
    /// звонок опознают на стороне АТС.
    public var sipLogin: String?

    /// Понятное имя. Может быть переопределено синхронизацией с EliteDash.
    ///
    /// Именно **отдельное поле**, а не замена номеру и логину. Записать
    /// псевдоним поверх исходного нельзя: пересчитать его заново потом будет не
    /// из чего, а список имён у EliteDash со временем меняется — и вчерашняя
    /// история осталась бы с позавчерашними именами без возможности исправить.
    public var displayName: String?

    /// Профиль, с которого шёл звонок.
    public var profileID: UUID?

    /// Метка профиля на момент звонка.
    ///
    /// Копией, а не ссылкой на профиль: метку правит сам менеджер, профиль
    /// может быть удалён, а история обязана остаться читаемой. Иначе строка
    /// годичной давности показывала бы сегодняшнее название или пустоту.
    public var profileLabel: String?

    public var startedAt: Date

    /// Когда звонок ответили. nil — не ответили вовсе.
    public var answeredAt: Date?

    /// Когда звонок закончился. nil — ещё идёт либо приложение завершилось
    /// посреди разговора и запись не успела закрыться.
    public var endedAt: Date?

    /// Причина завершения — той же строкой, что видел оператор на панели.
    public var endReason: String?

    public var wasTransferred: Bool
    public var wasConference: Bool

    public init(
        id: UUID = UUID(),
        callID: String,
        serverCallID: String? = nil,
        direction: Direction,
        role: Role = .primary,
        number: String,
        sipLogin: String? = nil,
        displayName: String? = nil,
        profileID: UUID? = nil,
        profileLabel: String? = nil,
        startedAt: Date = Date(),
        answeredAt: Date? = nil,
        endedAt: Date? = nil,
        endReason: String? = nil,
        wasTransferred: Bool = false,
        wasConference: Bool = false
    ) {
        self.id = id
        self.callID = callID
        self.serverCallID = serverCallID
        self.direction = direction
        self.role = role
        self.number = number
        self.sipLogin = sipLogin
        self.displayName = displayName
        self.profileID = profileID
        self.profileLabel = profileLabel
        self.startedAt = startedAt
        self.answeredAt = answeredAt
        self.endedAt = endedAt
        self.endReason = endReason
        self.wasTransferred = wasTransferred
        self.wasConference = wasConference
    }

    /// Разговор состоялся.
    public var isAnswered: Bool { answeredAt != nil }

    /// Пропущенный — входящий, на который не ответили.
    ///
    /// Исходящий без ответа пропущенным не считается: его никто не пропускал,
    /// там просто не взяли трубку, и в фильтре «пропущенные» ему делать нечего.
    public var isMissed: Bool { direction == .incoming && answeredAt == nil }

    /// Длительность разговора — от ответа до конца, а не от начала.
    ///
    /// nil, пока разговор не закончился или не начинался. Гудки в длительность
    /// не входят: «две минуты» в истории должны значить две минуты разговора,
    /// иначе сравнивать записи между собой бессмысленно.
    public var duration: TimeInterval? {
        guard let answeredAt, let endedAt else { return nil }
        return max(0, endedAt.timeIntervalSince(answeredAt))
    }

    /// Что показать в строке вместо номера, когда есть что.
    public var title: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return number.isEmpty ? "неизвестный номер" : number
    }
}
