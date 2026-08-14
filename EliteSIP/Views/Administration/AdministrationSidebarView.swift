import AppKit
import SwiftUI

/// Боковой список разделов «Управления».
///
/// **Список рисует система, а не мы.** Вью — это `List` со стилем
/// `SidebarListStyle` внутри `NSSplitViewItem.sidebar`: тот же кит, на котором
/// стоят сайдбары Finder и Music. Оба яруса системные, и оба берут на себя то,
/// что здесь раньше повторялось руками:
///
/// - половина сплита — материал и, под стеклом, плавающая вставка на всю высоту
///   окна со светофором внутри;
/// - `List` со стилем сайдбара — шаг строки, поля, заголовки групп, вид
///   выбранной строки, реакцию на курсор и прокрутку, которая уходит под
///   светофор с размытием на кромке.
///
/// Сам список одинаков в обоих оформлениях окна (`Theme.Chrome`): разный только
/// корпус вокруг него — стеклянная вставка на macOS 26 и обычная половина с
/// разделителем ниже. Здесь эта разница видна ровно в одном месте — подложке.
///
/// Отсюда три правила, каждое из которых до этого нарушалось:
///
/// 1. **Фона здесь нет.** Своя подложка поверх системной дала бы двойной
///    материал — мутный там, где обещано стекло.
/// 2. **Своей плашки выделения нет.** Её рисует список, и на macOS 26 это
///    акцентная капсула из нового набора, а не наша серая заливка.
/// 3. **Своей подсветки под курсором нет.** Системный сайдбар на наведение не
///    отвечает вовсе — подсвечивается только то, что нажимают. `hoverHighlight`
///    здесь читался как чужой элемент, потому что чужим и был.
///
/// Свои остались две вещи, которых у системы нет: значки из собственного
/// комплекта (SF Symbols нет на Catalina) и точка несохранённого.
struct AdministrationSidebarView: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: AdministrationRouter

    /// Корпус, в котором собрана эта половина. Не `Theme.Chrome`: см.
    /// `windowUsesGlass`.
    @Environment(\.windowUsesGlass) private var usesGlass

    /// Под стеклом у списка нет **никакой** подложки, и это не то же самое, что
    /// прозрачная.
    ///
    /// Первый заход ставил `Color.clear` в обеих ветках, чтобы не городить
    /// развилку, — и живое окно его отвергло: сам факт `background` на списке
    /// сбивает системную раскладку вставки. Замер: первая строка уехала на семь
    /// точек вниз, девять пунктов перестали влезать в минимальную высоту окна, и
    /// у списка вылез полноразмерный скроллер, отрезавший «Обслуживание» до
    /// «Обслужива…». Поэтому ветки две, и под стеклом модификатора нет вовсе.
    var body: some View {
        if usesGlass {
            list
        } else {
            // Без стекла список остаётся полупрозрачным и сливается с
            // содержимым: сайдбарной половины сплита, которая раньше давала
            // подложку, в этом варианте нет. Цвет системный, а не подобранный —
            // свой пришлось бы держать в двух темах и всё равно разойтись с
            // системой на следующей версии.
            list
                // Своя подложка снизу — и снятая подложка списка сверху.
                //
                // Одного `background` мало: `List` со стилем сайдбара рисует
                // собственный полупрозрачный фон **поверх** него, и список
                // оставался стеклянным при выключенном стекле. Убрать его
                // умеет только `scrollContentBackground`, и он с macOS 13 —
                // ниже список останется полупрозрачным, но там это и есть
                // системный вид.
                .compatHiddenScrollBackground()
                .compatBackground { Color(NSColor.controlBackgroundColor) }
        }
    }

    private var list: some View {
        List(selection: selection) {
            ForEach(AdministrationSection.groups) { group in
                if let title = group.title {
                    Section(header: Text(title)) {
                        rows(group.items)
                    }
                } else {
                    Section {
                        rows(group.items)
                    }
                }
            }
        }
        .listStyle(SidebarListStyle())
        // Отступ сверху — свой, а не системный. Под стеклом системный меряется
        // по всей полосе заголовка вместе с панелью инструментов, и первая
        // строка уезжала от светофора на 66 точек вместо тех четырёх, на которые
        // от него отступает строка состояния панели. В обычном оформлении это
        // просто поле от края, см. `Theme.Metrics.sidebarTopInset`.
        .compatOwnTopInset(Theme.Metrics.sidebarTopInset(glass: usesGlass))
    }

    /// Выбранный раздел глазами списка.
    ///
    /// Списку нужен необязательный выбор — он умеет снимать его целиком, —
    /// а окну пустой раздел показывать нечем. Поэтому `nil` от списка
    /// отбрасывается: щелчок мимо строки оставляет открытым тот раздел, что
    /// был.
    private var selection: Binding<AdministrationSection?> {
        Binding(
            get: { router.section },
            set: { if let new = $0 { router.section = new } }
        )
    }

    private func rows(_ items: [AdministrationSection]) -> some View {
        ForEach(items) { item in
            row(item).tag(item)
        }
    }

    private func row(_ item: AdministrationSection) -> some View {
        HStack(spacing: Theme.Metrics.elementSpacing) {
            icon(item)

            Text(item.title)
                .lineLimit(1)

            Spacer(minLength: 0)

            // Точка «здесь есть несохранённое».
            //
            // При семи вкладках хватало общего значка внизу окна. При девяти
            // разделах человек видит «есть несохранённое» и идёт искать, где
            // именно, — а перед «Отменить» он должен понимать, что теряет.
            if isDirty(item) {
                Circle()
                    .fill(Theme.Palette.unsaved)
                    .frame(
                        width: Theme.Metrics.adminDirtyDotDiameter,
                        height: Theme.Metrics.adminDirtyDotDiameter
                    )
            }
        }
    }

    /// Значок раздела.
    ///
    /// Акцентного цвета, как в системных сайдбарах, — но только у невыбранной
    /// строки. У выбранной цвет задаёт список: на её капсуле и значок, и
    /// подпись становятся белыми, а наш акцент остался бы синим по синему.
    @ViewBuilder
    private func icon(_ item: AdministrationSection) -> some View {
        let symbol = CompatSymbol(name: item.symbol, size: Theme.Icon.sidebar)
        if router.section == item {
            symbol
        } else {
            symbol.compatForeground(Color.accentColor)
        }
    }

    /// Разошлось ли содержимое раздела со снимком, снятым при входе.
    ///
    /// Сравнение поимённое, а не по всему `settings`: иначе точка загоралась бы
    /// у всех девяти разделов сразу и не сообщала бы ничего. Раздел
    /// «Обслуживание» своих настроек не имеет — его действия либо немедленные,
    /// либо ложатся в тот же черновик и зажигают точки там, где значения
    /// действительно разошлись.
    private func isDirty(_ item: AdministrationSection) -> Bool {
        guard let snapshot = model.administrationSnapshot else { return false }
        let now = model.settings

        switch item {
        case .account:
            return now.profiles != snapshot.profiles
        case .presets:
            return now.presets != snapshot.presets
        case .pbx:
            return now.conference != snapshot.conference
                || now.portKnock != snapshot.portKnock
                || now.audio.prefersWideband != snapshot.audio.prefersWideband
        case .incoming:
            return now.incomingCall != snapshot.incomingCall
        case .macros:
            return now.dtmf != snapshot.dtmf
        case .queues:
            return now.queues != snapshot.queues
        case .history:
            return now.history != snapshot.history
        case .diagnostics:
            // `plainChrome` здесь больше не проверяется: выключатель уехал к
            // менеджеру, в этом окне его нет, и разойтись со снимком он может
            // только вместе с перезапуском приложения.
            return now.minimumLogLevel != snapshot.minimumLogLevel
                || now.logFile != snapshot.logFile
        case .access:
            return now.admin != snapshot.admin
                || model.pendingAdminPassword != nil
                || model.pendingAdminPasswordRemoval
        case .maintenance:
            return false
        }
    }
}
