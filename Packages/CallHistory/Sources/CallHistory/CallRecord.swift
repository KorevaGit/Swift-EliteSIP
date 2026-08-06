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

    /// Чем кончился звонок — одним словом.
    ///
    /// **Кодом, а не разбором строки.** Причина уже хранится в `endReason` той
    /// же формулировкой, которую видел оператор на панели, и вывести из неё
    /// короткое слово можно было бы сравнением с образцами. Так делать нельзя:
    /// стоит поменять формулировку на панели — и история молча начнёт писать
    /// «отказ» вместо «занято», причём ни один тест этого не заметит, потому что
    /// обе строки правильные, просто разные. Код ставится в момент, когда ответ
    /// сервера ещё разобран на части, и после этого не зависит ни от чьих слов.
    ///
    /// Значения начинаются с единицы: колонка появилась миграцией и у старых
    /// записей пуста, а `Row.integer` отдаёт ноль и на пустоту тоже. Ноль как
    /// «код не записан» позволяет не заводить отдельный accessor ради одной
    /// колонки.
    public enum Outcome: Int, Sendable, Hashable, CaseIterable {

        /// Разговор состоялся. Слова у него нет — вместо него длительность.
        case completed = 1
        /// Входящий, на который не ответили.
        case missed = 2
        /// 486, 600.
        case busy = 3
        /// 408, 480, 487 — никто не снял трубку, или мы не дождались.
        case noAnswer = 4
        /// 404.
        case unknownNumber = 5
        /// 403, 603.
        case declined = 6
        /// Всё остальное. Код ответа остаётся в `endReason` и в журнале.
        case failed = 7

        /// Слово в колонке длительности. Шесть слов на все неудачи, и это
        /// потолок: седьмое означало бы, что оператору предлагают различать
        /// то, на что он всё равно ответит одинаково.
        public var title: String? {
            switch self {
            case .completed: return nil
            case .missed: return "пропущен"
            case .busy: return "занято"
            case .noAnswer: return "не ответил"
            case .unknownNumber: return "нет номера"
            case .declined: return "отклонён"
            case .failed: return "отказ"
            }
        }

        /// Перевод кода ответа SIP в слово.
        ///
        /// Живёт здесь, а не в приложении, потому что рядом с самим словарём:
        /// добавить исход и забыть про отображение — то же самое, что добавить
        /// его без смысла.
        public static func forFailure(status: Int) -> Outcome {
            switch status {
            case 486, 600: return .busy
            case 404: return .unknownNumber
            case 403, 603: return .declined
            // 487 — это наш же CANCEL: мы положили трубку раньше, чем взяли ту.
            // Для оператора это неотличимо от «не ответил», и различать их
            // отдельным словом означало бы объяснять ему устройство SIP.
            case 408, 480, 487: return .noAnswer
            default: return .failed
            }
        }
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

    /// Код исхода, записанный в момент завершения.
    ///
    /// nil у записей, заведённых до появления колонки, и у тех, чей исход
    /// выводится однозначно и без сервера, — см. `outcome`.
    public var outcomeCode: Outcome?

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
        outcomeCode: Outcome? = nil,
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
        self.outcomeCode = outcomeCode
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

    /// Исход, как его показывает история.
    ///
    /// Записанный код — не единственный источник, и это сделано нарочно. Две
    /// вещи выводятся однозначно и без сервера: состоявшийся разговор виден по
    /// времени ответа, а пропущенный — по направлению вместе с его отсутствием.
    /// Хранить их кодом значило бы завести второе место, где может лежать
    /// другая правда, — а фильтр «Пропущенные» всё равно отбирает по
    /// `answered_at`, и разойтись эти два ответа не имеют права.
    ///
    /// Порядок проверок поэтому такой: ответили — разговор; входящий без
    /// ответа — пропущенный; дальше уже то, что сказал сервер; а если он не
    /// сказал ничего (запись до миграции, обрыв без ответа) — «не ответил».
    public var outcome: Outcome {
        if isAnswered { return .completed }
        if direction == .incoming { return .missed }
        return outcomeCode ?? .noAnswer
    }
}
