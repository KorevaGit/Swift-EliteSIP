import AppKit
import SwiftUI

/// Боковой список разделов менеджерских настроек.
///
/// Устроен ровно как сайдбар «Управления» и по тем же правилам: список рисует
/// система (`List` со стилем сайдбара внутри `NSSplitViewItem`), своей подложки,
/// своей плашки выделения и своей подсветки под курсором здесь нет. Разбор,
/// почему каждое из этих правил именно такое, записан один раз — в
/// `AdministrationSidebarView`, и повторять его тут значило бы завести вторую
/// копию, которая разойдётся с первой.
///
/// Отличий от того сайдбара два, и оба — от того, что здесь нет черновика:
///
/// 1. **Групп нет.** Четыре пункта одним списком читаются без заголовков, а
///    «Звук · Звонок» под подписью «Вызов» — это подпись длиннее своей группы.
/// 2. **Точки несохранённого нет.** Менеджерские настройки применяются сразу,
///    и сообщать об отложенном нечего.
struct ManagerSidebarView: View {

    @EnvironmentObject private var router: ManagerRouter

    /// Корпус, в котором собрана эта половина. Не `Theme.Chrome`: см.
    /// `windowUsesGlass`.
    @Environment(\.windowUsesGlass) private var usesGlass

    /// Сколько от верха этой половины до нижней кромки светофора. `nil` —
    /// ещё не замерено, тогда идёт прежний расчёт по высоте полосы заголовка.
    @State private var lightsBottom: CGFloat?

    /// Отступ первой строки: под светофором и с воздухом под ним.
    ///
    /// В обычном оформлении список начинается ниже полосы заголовка, светофор
    /// оказывается над этой половиной, замер выходит отрицательным — и отступа
    /// нет вовсе, как и было.
    private var topInset: CGFloat {
        guard let lightsBottom, lightsBottom > 0 else {
            return Theme.Metrics.sidebarTopInset(glass: usesGlass)
        }
        return lightsBottom + Theme.Metrics.trafficLightsToList
    }

    /// Ветки две, и под стеклом модификатора фона нет вовсе — не `Color.clear`,
    /// а именно ничего: сам факт `background` на списке сбивает системную
    /// раскладку плавающей вставки. Замер и последствия — в
    /// `AdministrationSidebarView`.
    var body: some View {
        if usesGlass {
            list
        } else {
            list
                .compatHiddenScrollBackground()
                .compatBackground { Color(NSColor.controlBackgroundColor) }
        }
    }

    private var list: some View {
        List(selection: selection) {
            // Голый `ForEach`, без `Section`, и в «Управлении» безымянная
            // группа теперь тоже без неё. Обёртка ставилась ради полей сверху,
            // одинаковых у двух окон, а на Big Sur дала пустую полосу под
            // заголовок, которого нет. Поля задаёт `compatOwnTopInset` ниже.
            ForEach(ManagerSection.allCases) { item in
                row(item).tag(item)
            }
        }
        .listStyle(SidebarListStyle())
        .compatOwnTopInset(topInset) {
            // Измеритель живёт внутри самой вставки: её верх и есть верх
            // половины, а фон списку давать нельзя — см. `compatOwnTopInset`.
            WindowButtonsInsetReader { _, bottom in lightsBottom = bottom }
        }
    }

    /// Выбранный раздел глазами списка. `nil` от списка отбрасывается: щелчок
    /// мимо строки оставляет открытым тот раздел, что был, — показывать пустоту
    /// окну нечем.
    private var selection: Binding<ManagerSection?> {
        Binding(
            get: { router.section },
            set: { if let new = $0 { router.section = new } }
        )
    }

    private func row(_ item: ManagerSection) -> some View {
        HStack(spacing: Theme.Metrics.elementSpacing) {
            icon(item)

            Text(item.title)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    /// Акцентного цвета, как в системных сайдбарах, — но только у невыбранной
    /// строки: на капсуле выбранной цвет задаёт список, и наш акцент остался бы
    /// синим по синему.
    @ViewBuilder
    private func icon(_ item: ManagerSection) -> some View {
        let symbol = CompatSymbol(name: item.symbol, size: Theme.Icon.sidebar)
        if router.section == item {
            symbol
        } else {
            symbol.compatForeground(Color.accentColor)
        }
    }
}
