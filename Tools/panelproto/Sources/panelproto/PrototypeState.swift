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
    /// Вторая линия — второй источник прыжков в нынешней панели.
    @Published var hasSecondLine = false
    /// Поле перевода — третий.
    @Published var isTransferVisible = false
    @Published var transferNumber = ""

    @Published var macroCount = 9

    @Published var isDark = true

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

    /// Номер, под которым менеджер зарегистрирован. Виден всегда: профилей
    /// несколько, и «под каким номером я сейчас работаю» — первый вопрос.
    @Published var managerNumber = "176"

    var isInCall: Bool { phase != .idle }

    var statusColor: Color {
        hasRegistrationFailure ? Tokens.Palette.failure : Tokens.Palette.answer
    }

    var statusText: String {
        hasRegistrationFailure ? "нет связи" : "на линии"
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
