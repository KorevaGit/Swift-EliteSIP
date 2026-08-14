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

    var title: String {
        switch self {
        case .account: "Аккаунт"
        case .presets: "Предустановки"
        case .pbx: "АТС"
        case .incoming: "Входящие"
        case .macros: "Макросы"
        case .queues: "Очереди"
        case .history: "История"
        case .diagnostics: "Диагностика"
        case .access: "Доступ"
        case .maintenance: "Обслуживание"
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
        case .macros: "Вызов"
        case .history: "Машина"
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
