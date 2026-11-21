import SwiftUI

/// Разделы окна «Управление» и то, какой из них открыт.
///
/// Вынесены из вью, потому что с этапа 5 окно собрано системным
/// `NSSplitViewController`: сайдбар и содержимое — два разных контроллера с
/// двумя разными деревьями SwiftUI, и общее состояние им негде хранить, кроме
/// как снаружи.
enum AdministrationSection: String, CaseIterable, Identifiable {

    /// Пять разделов, как в «Управлении» Windows-клиента 1.0.4: подключение
    /// (профили, АТС, стук), клавиши, входящие (очереди, автоответ, защита),
    /// система (история, журнал, доступ, обслуживание) и Spark.
    case connection, macros, incoming, system, spark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection: NSLocalizedString("Подключение", comment: "раздел «Управления»")
        case .macros: NSLocalizedString("Клавиши", comment: "раздел «Управления»")
        case .incoming: NSLocalizedString("Входящие", comment: "раздел «Управления»")
        case .system: NSLocalizedString("Система", comment: "раздел «Управления»")
        case .spark: "Spark"
        }
    }

    /// Значки Lucide — те же, что в сайдбаре «Управления» Windows.
    var symbol: String {
        switch self {
        case .connection: "Lucide/network"
        case .macros: "Lucide/panels-top-left"
        case .incoming: "Lucide/headset"
        case .system: "Lucide/monitor"
        case .spark: "Lucide/cloud"
        }
    }

    /// Групп у пяти разделов нет — как в Windows, один список.
    var group: String? { nil }

    static var groups: [Group] {
        var result: [Group] = []
        for item in allCases {
            if let title = item.group {
                result.append(Group(title: title, items: [item]))
            } else if result.isEmpty {
                result.append(Group(title: nil, items: [item]))
            } else {
                result[result.count - 1].items.append(item)
            }
        }
        return result
    }

    /// Пачка разделов под общим заголовком. У первой заголовка нет — см.
    /// `group`.
    struct Group: Identifiable {
        var title: String?
        var items: [AdministrationSection]
        var id: String { title ?? "" }
    }
}

/// Какой раздел открыт. Общее состояние двух половин окна.
///
/// Класс, а не `@State`: сайдбар и содержимое живут в разных
/// `NSHostingController`, и связать их можно только объектом, который держит
/// окно.
@MainActor
final class AdministrationRouter: ObservableObject {

    @Published var section: AdministrationSection = .connection
}
