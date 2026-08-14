import SwiftUI

/// Разделы окна «Управление» и то, какой из них открыт.
///
/// Вынесены из вью, потому что с этапа 5 окно собрано системным
/// `NSSplitViewController`: сайдбар и содержимое — два разных контроллера с
/// двумя разными деревьями SwiftUI, и общее состояние им негде хранить, кроме
/// как снаружи.
enum AdministrationSection: String, CaseIterable, Identifiable {

    case account, presets, pbx, incoming
    case macros, queues
    case history, diagnostics, access, maintenance

    var id: String { rawValue }

    /// `NSLocalizedString`, а не литерал: раздел — это `String`, а не вью, и
    /// ключом он сам по себе не станет. `String(localized:)` подошёл бы лучше,
    /// но он с macOS 12, а нижняя планка проекта — Catalina.
    var title: String {
        switch self {
        case .account: NSLocalizedString("Аккаунт", comment: "раздел «Управления»")
        case .presets: NSLocalizedString("Предустановки", comment: "раздел «Управления»")
        case .pbx: NSLocalizedString("АТС", comment: "раздел «Управления»")
        case .incoming: NSLocalizedString("Входящие", comment: "раздел «Управления»")
        case .macros: NSLocalizedString("Макросы", comment: "раздел «Управления»")
        case .queues: NSLocalizedString("Очереди", comment: "раздел «Управления»")
        case .history: NSLocalizedString("История", comment: "раздел «Управления»")
        case .diagnostics: NSLocalizedString("Диагностика", comment: "раздел «Управления»")
        case .access: NSLocalizedString("Доступ", comment: "раздел «Управления»")
        case .maintenance: NSLocalizedString("Обслуживание", comment: "раздел «Управления»")
        }
    }

    /// Всё из имеющегося комплекта: новых значков этап не добавляет, и долг
    /// этапа 7 по дорисовке от него не растёт.
    var symbol: String {
        switch self {
        case .account: "person.crop.circle"
        // Своего значка у предустановок в комплекте нет, и новый этап не
        // рисует (долг этапа 7). `person.badge.plus` ближе прочего по смыслу:
        // предустановкой заводят рабочее место.
        case .presets: "person.badge.plus"
        case .pbx: "phone.arrow.right"
        case .incoming: "bell"
        case .macros: "square.grid.3x3"
        case .queues: "person.3.fill"
        case .history: "clock"
        case .diagnostics: "stethoscope"
        case .access: "lock.shield.fill"
        case .maintenance: "hammer.fill"
        }
    }

    /// Заголовок группы, если раздел её открывает.
    ///
    /// Группы отвечают на «про что этот раздел»: без них десять пунктов
    /// читаются одним списком, в котором «Очереди» стоят рядом с «Историей» без
    /// всякой причины.
    ///
    /// У первой группы заголовка нет намеренно. В системных сайдбарах первая
    /// пачка тоже идёт без подписи — у Finder «Recents» и «Shared» стоят до
    /// «Favorites», — а подпись над самой верхней строкой ещё и отодвигала бы её
    /// от светофора, ломая выравнивание, ради которого сайдбар вообще уходит под
    /// полосу заголовка.
    var group: String? {
        switch self {
        // «Вызов», а не «Обслуживание вызова»: прежнее занимало 133 точки — на
        // 44 больше самого длинного своего пункта — и в одиночку держало ширину
        // всей панели.
        case .macros: NSLocalizedString("Вызов", comment: "группа разделов «Управления»")
        case .history: NSLocalizedString("Машина", comment: "группа разделов «Управления»")
        default: nil
        }
    }

    /// Те же разделы, но уже разложенные по группам.
    ///
    /// Раскладку делает модель, а не вью: системный список складывается из
    /// `Section`, и порядок «заголовок — его пункты» ему нужен готовым, а не
    /// восстановленным по ходу перебора.
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

    @Published var section: AdministrationSection = .account
}
