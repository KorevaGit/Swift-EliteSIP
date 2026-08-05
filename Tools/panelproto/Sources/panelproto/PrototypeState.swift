import SwiftUI

/// Заглушка состояния вместо `AppModel`.
///
/// Прототип обсуждает компоновку, поэтому здесь нет ни SIP, ни звука: только те
/// поля, от которых зависит, что видно на экране.
@MainActor
final class PrototypeState: ObservableObject {

    enum Phase: String, CaseIterable, Identifiable {
        case idle = "Покой"
        case dialing = "Вызов"
        case active = "Разговор"

        var id: String { rawValue }
    }

    enum Size: String, CaseIterable, Identifiable {
        case compact = "Компактный"
        case full = "Полный"

        var id: String { rawValue }
    }

    struct Macro: Identifiable {
        let id = UUID()
        let title: String
    }

    /// Профиль в выпадающем списке: номер и пометка.
    ///
    /// Пометка нужна ровно затем, зачем она есть в профилях приложения: два
    /// профиля одного добавочного различаются только адресом сервера, и по
    /// номеру их не отличить.
    struct Profile: Identifiable, Hashable {
        let id = UUID()
        let number: String
        let label: String
    }

    /// Что мешает работать. Всё это встаёт в один и тот же слот между списком и
    /// шестерёнкой — и ничего из этого не двигает панель.
    enum Trouble: String, CaseIterable, Identifiable {
        case none = "Всё в порядке"
        case connecting = "Подключение"
        case noNetwork = "Нет сети"
        case needsSetup = "Профиль без пароля"
        case failed = "Сервер отказал"

        var id: String { rawValue }

        /// Текст в строке. Пустой — слот молчит.
        var text: String {
            switch self {
            case .none: return ""
            case .connecting: return "Подключение…"
            case .noNetwork: return "Нет сети"
            case .needsSetup: return "Профиль без пароля"
            case .failed: return "Сервер отказал · повтор в 14:32"
            }
        }

        /// Ведёт ли надпись в настройки. Ведёт только то, что чинит человек:
        /// сеть и сервер починятся сами, и нажимать там не на что.
        var opensSettings: Bool { self == .needsSetup }
    }

    @Published var phase: Phase = .idle
    @Published var size: Size = .full

    @Published var dialedNumber = ""
    @Published var callerNumber = "+7 918 000-11-22"
    @Published var callerName: String? = "Лид · Сочи"
    @Published var callSeconds = 0

    @Published var isOnHold = false
    @Published var isMuted = false

    /// Полоса сбоя регистрации. Проверяем ей главное: она не должна двигать низ.
    @Published var hasRegistrationFailure = false
    /// Что показывает слот между списком профилей и шестерёнкой.
    @Published var trouble: Trouble = .none
    /// Отключён вручную — выбран пункт «Отключён» в списке. Отдельно от
    /// `trouble`: это не беда, а решение оператора, и говорит о нём цвет точки,
    /// а не текст в строке.
    @Published var isOfflineByChoice = false
    /// Вторая линия — второй источник прыжков в нынешней панели.
    @Published var hasSecondLine = false
    /// Поле перевода — третий.
    @Published var isTransferVisible = false
    @Published var transferNumber = ""

    @Published var macroCount = 9

    @Published var isDark = true

    /// Живая панель или картинка для листа состояний.
    ///
    /// `ImageRenderer` рисует вьюху вне окна и всё, что упирается в AppKit,
    /// заменяет жёлтой заглушкой: и `TextField`, и вид-якорь под списком
    /// профилей. На листе они и не нужны — там нечего набирать и не во что
    /// нажимать, — а вот выдавать заглушку за компоновку нельзя.
    let isInteractive: Bool

    init(isInteractive: Bool = true) {
        self.isInteractive = isInteractive
    }

    /// Чем сделана поверхность панели. По умолчанию — стекло: на машине, где
    /// макет собирают, оно есть, и обсуждать прозрачность имеет смысл на нём.
    @Published var glass: Tokens.Glass = .glass

    /// Сила подкраски поверхности. 0 — совсем прозрачно, 1 — почти
    /// непрозрачный фон. Ручка ради того и выведена: величина подбирается
    /// глазами поверх настоящей CRM, а закрепляется числом.
    @Published var surfaceTint: Double = 0.57

    var macros: [Macro] {
        Array(Self.allMacros.prefix(macroCount))
    }

    /// Подписи взяты нарочно разной длины: именно они ломают сетку, если её
    /// строить на равных колонках.
    private static let allMacros = [
        Macro(title: "Перевод"),
        Macro(title: "Отдел продаж"),
        Macro(title: "Склад"),
        Macro(title: "Бухгалтерия"),
        Macro(title: "Конференция"),
        Macro(title: "Гудок"),
        Macro(title: "Секретарь"),
        Macro(title: "Тех. отдел"),
        Macro(title: "Оператор"),
    ]

    /// Профили сотрудника. Номер виден всегда: профилей несколько, и «под каким
    /// номером я сейчас работаю» — первый вопрос.
    @Published var profiles: [Profile] = [
        Profile(number: "172", label: "Офис"),
        Profile(number: "172", label: "Удалённо"),
        Profile(number: "176", label: "Отдел продаж"),
    ]

    @Published var activeProfileIndex = 0

    var activeProfile: Profile { profiles[activeProfileIndex] }

    /// Номер в самой кнопке списка. Только номер, без пометки: он и есть ответ
    /// на «кто я сейчас», а пометка — способ выбрать в списке, а не подпись на
    /// панели. Пометка в кнопке съела бы половину строки, и слоту под беду
    /// осталось бы место на одно слово.
    var managerNumber: String { activeProfile.number }

    var isInCall: Bool { phase != .idle }

    /// Цвет точки в кнопке списка — единственное, чем показано обычное
    /// состояние. Текстом оно не дублируется: «На линии» рядом с зелёной точкой
    /// занимает место и не сообщает ничего сверх неё.
    var statusColor: Color {
        if isOfflineByChoice {
            return Tokens.Palette.textTertiary(isDark ? .dark : .light)
        }
        switch trouble {
        case .none: return Tokens.Palette.answer
        case .connecting: return Tokens.Palette.warning
        case .noNetwork, .needsSetup, .failed: return Tokens.Palette.failure
        }
    }

    /// Что стоит в слоте беды. Отключение вручную сюда не попадает.
    var troubleText: String {
        isOfflineByChoice ? "" : trouble.text
    }

    var callStateText: String {
        switch phase {
        case .idle: return ""
        case .dialing: return "Идёт вызов…"
        case .active:
            if isOnHold { return "На удержании" }
            if isMuted { return "Микрофон выключен" }
            return "Разговор"
        }
    }

    var timerText: String {
        String(format: "%02d:%02d", callSeconds / 60, callSeconds % 60)
    }

    func tick() {
        guard phase == .active else { return }
        callSeconds += 1
    }

    func press(digit: Character) {
        dialedNumber.append(digit)
    }

    func clear() {
        dialedNumber = ""
    }
}
