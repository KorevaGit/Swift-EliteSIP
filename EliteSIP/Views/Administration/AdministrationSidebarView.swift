import SwiftUI

/// Боковой список разделов «Управления».
///
/// **Материал рисует система, а не мы.** Вью живёт внутри
/// `NSSplitViewItem.sidebar` — того же кита, на котором стоят сайдбары Finder и
/// Music, — и он берёт на себя всё, что мы до этого повторяли руками:
/// полупрозрачную подложку, полную высоту под полосой заголовка, поведение при
/// изменении размера окна и стекло на macOS 26. Есть с 10.11, то есть работает и
/// на Catalina.
///
/// Отсюда и правило: **фон здесь прозрачный**. Своя подложка поверх системной
/// дала бы двойной материал — мутный там, где должно быть стекло.
struct AdministrationSidebarView: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: AdministrationRouter

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(AdministrationSection.allCases) { item in
                if let group = item.group {
                    Text(group)
                        .font(Font.footnote.weight(.semibold))
                        .compatForeground(Theme.Palette.textSecondary)
                        .padding(.horizontal, Theme.Metrics.adminSidebarRowPadding)
                        .padding(.top, Theme.Metrics.sectionSpacing)
                        .padding(.bottom, Theme.Metrics.hairSpacing)
                }

                row(item)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metrics.elementSpacing)
        .padding(.bottom, Theme.Metrics.elementSpacing)
        // Сверху — ровно столько же, сколько у содержимого справа: под полосой
        // заголовка начинаются оба, и первая строка списка встаёт на одну линию
        // с первым заголовком раздела.
        .padding(.top, Theme.Gap.titleToStatus)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func row(_ item: AdministrationSection) -> some View {
        let isSelected = router.section == item
        return Button {
            router.section = item
        } label: {
            HStack(spacing: Theme.Metrics.elementSpacing) {
                // Значок и подпись одного тона, как в системном сайдбаре.
                //
                // До этого невыбранные значки брали вторичный цвет, и половина
                // списка читалась погашенной — будто эти разделы недоступны. У
                // Finder и Music невыбранный значок белый наравне с подписью, а
                // акцент достаётся только выбранному, и достаётся обоим.
                CompatSymbol(name: item.symbol, size: Theme.Icon.sidebar)
                    .compatForeground(isSelected ? Color.accentColor : Theme.Palette.textPrimary)

                Text(item.title)
                    .lineLimit(1)
                    .compatForeground(isSelected ? Color.accentColor : Theme.Palette.textPrimary)

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
            .font(.system(size: Theme.Metrics.adminSidebarFontSize))
            .padding(.horizontal, Theme.Metrics.adminSidebarRowPadding)
            .frame(height: Theme.Metrics.adminSidebarRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .compatBackground {
                // Выделение — мягкая заливка, а не акцентный стиль кнопки и не
                // сплошной синий. Акцентного стиля на Catalina нет вовсе, а
                // сплошная заливка требует белой подписи поверх — `.plain`
                // цвет текста не меняет, и на светлом акценте подпись стала бы
                // нечитаемой.
                RoundedRectangle(cornerRadius: Theme.Metrics.adminSidebarRadius)
                    .fill(isSelected ? Theme.Palette.sidebarSelection(scheme) : .clear)
            }
            // Нажатие ловит вся плашка, а не только буквы со значком.
            //
            // Без этого `.plain`-кнопка отдаёт под нажатие ровно нарисованное
            // содержимое: между значком и подписью, справа от текста и по краям
            // строки нажатие проваливалось мимо, и по пунктам сайдбара
            // промахивались.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(
            cornerRadius: Theme.Metrics.adminSidebarRadius,
            isEnabled: !isSelected
        )
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
