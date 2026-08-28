import Foundation

/// Управляемые поля предустановки, разобранные и **необязательные каждое**.
///
/// Это самая опасная часть линии предустановок, и опасность у неё одна:
/// **отсутствующее поле означает «панель им не управляет», а не «сбросить в
/// умолчание».** Машина обязана сохранить своё текущее значение. Правило
/// принято ещё в M8, и цена его нарушения названа там же: предустановка,
/// написанная ради макросов, молча стёрла бы политику защиты — на всех рабочих
/// местах разом и обязательным обновлением, которое сотрудник не может
/// отложить.
///
/// Отсюда всё устройство типа: каждое поле — `Optional`, и «нет значения»
/// выражено системой типов, а не соглашением. Применяющий код физически не
/// может перепутать «панель прислала ноль» с «панель ничего не присылала»: во
/// втором случае у него на руках `nil`, и присвоить его некуда.
///
/// Разбор терпимый — второе правило той же пары. Незнакомое поле пропускается,
/// понятное применяется, а **отказ от файла целиком недопустим**: тогда до
/// старой сборки не доедет и смена адреса АТС, без которой она не звонит.
/// Поэтому каждый блок разбирается сам по себе, и сломанный блок теряется в
/// одиночку, а не уносит остальные.
///
/// Зеркальное правило на стороне панели — строгость: незнакомый ключ при
/// сохранении ревизии там ошибка. Это единственное место, где опечатку в имени
/// поля ещё можно показать человеку.
public struct ManagedFields: Sendable, Equatable {

    public var dtmf: DTMF?
    public var incomingCall: CallGuard?
    public var conference: Conference?
    public var portKnock: PortKnock?
    public var siteAddresses: SiteAddresses?

    /// Живёт в приложении внутри активного профиля, а не в `AppSettings`, —
    /// поэтому и в контракте стоит полем верхнего уровня.
    public var acceptsAnyTLSCertificate: Bool?

    /// Протокол связи с АТС: `udp` или `tls`.
    ///
    /// Строкой, а не `SIPTransport`, потому что `PanelLink` не зависит от
    /// `SIPCore` и зависеть не должен: здесь разбор байтов панели, а не модель
    /// линии. Опознаёт строку тот, кто накладывает поля, — там же, где живёт
    /// правило «незнакомое не применяется».
    ///
    /// Управляется панелью потому, что это свойство АТС, а не машины: сменили
    /// на стороне сервера — сменить надо разом на всех местах. Порт с
    /// протоколом не приезжает: умолчания RFC 3261 приложение знает само.
    public var transport: String?

    // MARK: - Блоки

    public struct DTMF: Sendable, Equatable, Decodable {
        public var toneMilliseconds: Int?
        public var gapMilliseconds: Int?
        public var pauseMilliseconds: Int?
        public var macros: [Macro]?
        public var macroColumns: Int?
        public var macroHeight: Int?
        public var macroHeightIsManual: Bool?
    }

    public struct Macro: Sendable, Equatable, Decodable {
        /// Опознаёт клавишу между ревизиями: по нему панель считает, что
        /// изменилось, и по нему же клавиша остаётся собой при переименовании.
        public var id: String?
        public var title: String?
        public var sequence: String?

        /// Уводит ли клавиша звонок другому человеку.
        ///
        /// Отвечает администратор, а не догадка по коду: `*02` — это Attended
        /// Transfer конкретно боевого сервера, а не общее правило Asterisk.
        /// Пометка уходит в историю звонков, которую читают как свидетельство
        /// при разборе жалобы, поэтому угадывать её нельзя.
        public var transfersCall: Bool?
    }

    public struct CallGuard: Sendable, Equatable, Decodable {
        public var isEnabled: Bool?
        public var isRandomPositionEnabled: Bool?
        public var tunesRandomnessByHand: Bool?
        public var minimumTravel: Double?
        public var screenMargin: Double?
        public var targetCount: Int?
        public var requiresCursorMovement: Bool?
        public var tunesLivenessByHand: Bool?
        public var requiredCursorTravel: Double?
        public var requiredCursorSamples: Int?
        public var rejectsSyntheticEvents: Bool?

        /// `isServerManaged` здесь нет намеренно, хотя в `CallGuardPolicy` оно
        /// есть: приложение выводит его из режима машины — «Предустановка» или
        /// «Вручную», — а приехавшее полем оно означало бы два источника одного
        /// факта.
        private enum CodingKeys: String, CodingKey {
            case isEnabled, isRandomPositionEnabled, tunesRandomnessByHand
            case minimumTravel, screenMargin, targetCount
            case requiresCursorMovement, tunesLivenessByHand
            case requiredCursorTravel, requiredCursorSamples, rejectsSyntheticEvents
        }
    }

    public struct Conference: Sendable, Equatable, Decodable {
        public var featureCode: String?
        public var roomExtension: String?
    }

    public struct PortKnock: Sendable, Equatable, Decodable {
        public var steps: [KnockStep]?
        public var spacingSeconds: Double?
        public var repeatIntervalSeconds: Double?
    }

    public struct KnockStep: Sendable, Equatable, Decodable {
        /// Пустой адрес означает «основной адрес АТС».
        public var host: String?
        public var payloadBytes: Int?
        public var count: Int?
    }

    public struct SiteAddresses: Sendable, Equatable, Decodable {
        public var office: String?
        public var remote: String?
    }

    // MARK: - Разбор

    /// Разбирает управляемые поля. **Не бросает никогда.**
    ///
    /// Отсутствие броска — не небрежность, а требование: отказ от файла целиком
    /// недопустим. Что не разобралось, то остаётся `nil` и просто не
    /// применяется; машина сохраняет по этому полю своё текущее значение —
    /// ровно то же, что она сделала бы, если бы панель им не управляла.
    ///
    /// Блоки разбираются порознь по той же причине: испорченный `dtmf` не
    /// должен уносить с собой `siteAddresses`, без которого машина не звонит.
    public static func parse(_ data: Data) -> ManagedFields {
        var fields = ManagedFields()

        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return fields
        }

        fields.dtmf = decode(DTMF.self, from: root["dtmf"])
        fields.incomingCall = decode(CallGuard.self, from: root["incomingCall"])
        fields.conference = decode(Conference.self, from: root["conference"])
        fields.portKnock = decode(PortKnock.self, from: root["portKnock"])
        fields.siteAddresses = decode(SiteAddresses.self, from: root["siteAddresses"])
        fields.acceptsAnyTLSCertificate = root["acceptsAnyTLSCertificate"] as? Bool
        fields.transport = root["transport"] as? String

        return fields
    }

    /// Разбирает один блок, молча теряя непонятное.
    private static func decode<T: Decodable>(_ type: T.Type, from value: Any?) -> T? {
        guard let value, !(value is NSNull) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public init() {}
}
