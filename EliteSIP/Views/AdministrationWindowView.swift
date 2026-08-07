import AdminAccess
import AppKit
import SwiftUI

/// Окно «Управление» — закрытые настройки целиком.
///
/// **Правки не применяются на ходу.** Всё, что меняется внутри, живёт в памяти
/// до нажатия «Сохранить»: на диск не уходит ничего, включая пароли.
/// Причина в том, что сохранение здесь означает не «записал громкость», а
/// «объявил машину настроенной вручную», и такое объявление должно быть
/// отдельным действием. Отсюда же «Отменить»: шанс передумать нужен ровно
/// потому, что цена ошибки — чужое рабочее место.
///
/// **Менеджерских настроек здесь нет** (этап 5). До него они дублировались
/// второй вёрсткой — микрофон, наушники, AGC, отпускание устройства и весь
/// блок рингтона стояли в обоих окнах, — и дубли успели разойтись по текстам за
/// один этап. Пока это окно открыто, менеджерское не открывается: оба пишут в
/// один `settings`, запись придержана для всего сразу, и «Отменить» молча
/// откатило бы выбор, сделанный в соседнем окне.
struct AdministrationWindowView: View {

    @EnvironmentObject private var model: AppModel

    @Environment(\.colorScheme) private var scheme

    @State private var section: Section = .account
    @State private var isConfirmingSave = false

    var body: some View {
        // Ширина берётся у окна напрямую, а не через `PreferenceKey` с фона
        // прокрутки. Первый заход был именно таким, и живое окно его
        // опровергло: списки остались в одну колонку на 980 точках — то есть
        // порог не срабатывал вовсе, а обещанная вторая контрольная ширина
        // существовала только на бумаге.
        //
        // Цикла, который схлопнул окно настроек в этапе 2, здесь нет: там из
        // геометрии выводилась высота окна, и содержимое зависело от окна, а
        // окно от содержимого. Тут размер задаёт человек мышью, а содержимое
        // только читает результат.
        GeometryReader { proxy in
            // Черт нет ни одной. Между сайдбаром и содержимым — потому что
            // панель плавающая, и границу задаёт её собственный край; над
            // кнопками — потому что полоса низа и без того отделена от
            // содержимого своим положением, а черта рядом с краем панели
            // читалась как вторая, лишняя.
            //
            // Низ вынесен из правой колонки во всю ширину окна: раньше он
            // начинался на восемь точек правее панели, и «Сохранить» висело
            // в полосе, которая до сайдбара не доходила.
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    sidebar
                    content
                }

                footer
            }
            .environment(\.settingsListColumns, columns(forWindowWidth: proxy.size.width))
        }
        .frame(
            minWidth: Theme.Metrics.adminMinWidth,
            minHeight: Theme.Metrics.adminMinHeight
        )
        // Колонка подписей шире менеджерских 72: здесь «Отображаемое имя» и
        // «Время регистрации», а не «Громкость». На 72 каждая вторая подпись
        // переносилась бы в две строки.
        .environment(\.settingsLabelColumn, Theme.Metrics.adminLabelColumn)
        // Потолок ширины у строк «подпись — управление». Без него растяжимое
        // окно даёт поле ввода домена длиной во весь монитор, а пояснение —
        // строкой в полтораста знаков; и то и другое читается как сбой, а не
        // как простор. Настоящие списки потолка не знают и растягиваются.
        .environment(\.settingsRowMaxWidth, Theme.Metrics.adminContentMaxWidth)
        // Безопасную зону игнорирует только фон, а не раскладка: материал обязан
        // накрыть полосу заголовка, иначе светофор с названием повиснут над
        // чужим окном. Ловушка, стоившая настройкам итерации, здесь не
        // срабатывает — размер окна свой и меняется мышью, сходиться нечему.
        .compatBackground {
            Color.clear
                .themedPanelSurface(cornerRadius: 0)
                .compatIgnoreSafeArea()
        }
        // Заголовок окна — имя раздела, как у Finder имя текущей папки.
        //
        // Постоянное «Управление EliteSIP» отвечало на «какое это окно», но в
        // переключателе окон и в Mission Control этого мало: разделов девять, и
        // человек ищет тот, где он был. Тем же `WindowTitle`, что у истории с
        // именем профиля, — второго способа менять заголовок в приложении нет.
        .compatBackground { WindowTitle(title: section.title) }
    }

    /// Единственный порог перестроения, считанный от ширины окна.
    ///
    /// Из ширины вычитается всё, что списку не достаётся: сайдбар с полями
    /// вокруг него, поля содержимого по краям и отступы плашки раздела. Иначе
    /// порог сработал бы раньше, чем список действительно получил бы место.
    private func columns(forWindowWidth width: CGFloat) -> Int {
        let available = width
            - Theme.Metrics.adminSidebarWidth
            - Theme.Metrics.sectionSpacing * 2
            - Theme.Metrics.contentPadding * 2
            - Theme.Metrics.sectionSpacing * 2
        return available >= Theme.Metrics.adminTwoColumnThreshold ? 2 : 1
    }

    // MARK: - Боковой список

    /// Разделы окна.
    ///
    /// Свой список кнопок, а не `NavigationSplitView` (macOS 13) и не
    /// `List(.sidebar)`. Причина та же, по которой раньше был отвергнут
    /// системный `TabView`: системный сайдбар на Catalina либо отсутствует,
    /// либо ведёт себя иначе, и получилась бы ветка версий ровно там, где
    /// принцип 5 требует одного вида на всех трёх системах.
    enum Section: String, CaseIterable, Identifiable {

        case account, pbx, incoming
        case macros, queues
        case history, diagnostics, access, maintenance

        var id: String { rawValue }

        var title: String {
            switch self {
            case .account: "Аккаунт"
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
        /// Группы не декоративные: они отвечают на «про что этот раздел» —
        /// про связь, про обслуживание вызова или про саму машину. Без них
        /// девять пунктов читаются одним списком, в котором «Очереди» стоят
        /// рядом с «Историей» без всякой причины.
        var group: String? {
            switch self {
            case .account: "Рабочее место"
            // «Вызов», а не «Обслуживание вызова»: прежнее занимало 133 точки —
            // на 44 больше самого длинного своего пункта — и в одиночку держало
            // ширину всей панели.
            case .macros: "Вызов"
            case .history: "Машина"
            default: nil
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Section.allCases) { item in
                if let group = item.group {
                    Text(group)
                        .font(Font.footnote.weight(.semibold))
                        .compatForeground(Theme.Palette.textSecondary)
                        .padding(.horizontal, Theme.Metrics.sectionSpacing)
                        .padding(.top, Theme.Metrics.sectionSpacing)
                        .padding(.bottom, Theme.Metrics.hairSpacing)
                }

                sidebarRow(item)
            }

            Spacer(minLength: 0)
        }
        .padding(Theme.Metrics.elementSpacing)
        // Тот же отступ сверху, что у содержимого справа и у страницы настроек:
        // не край окна, а полоса заголовка, и расстояние от светофора до первой
        // строки везде одно.
        .padding(.top, Theme.Gap.titleToStatus)
        .frame(width: Theme.Metrics.adminSidebarWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        // Панель уходит под светофор, как в Finder: материал накрывает полосу
        // заголовка, а строки списка остаются под ней.
        //
        // Безопасную зону отдаёт **только фон и только сверху**. Само содержимое
        // её уважает — иначе первая строка встала бы вровень со светофором и
        // упёрлась в него, а поля слева, справа и снизу задаёт раскладка, и
        // отдать их значило бы приклеить панель к краям окна.
        //
        // На Catalina это работает тем же способом, что и в трёх других окнах
        // приложения: `.fullSizeContentView` с прозрачной полосой заголовка
        // есть с 10.15, а `edgesIgnoringSafeArea` — замена `ignoresSafeArea` из
        // macOS 11. Числа полосы заголовка здесь нет и не нужно: её высоту
        // отдаёт сама безопасная зона, а она разная — замер живого окна дал 32
        // точки на macOS 26 против 28 на прежних версиях.
        .compatBackground {
            Color.clear
                .themedSidebarSurface()
                .compatIgnoreSafeArea(.top)
        }
        .padding(.horizontal, Theme.Metrics.sectionSpacing)
        .padding(.bottom, Theme.Metrics.sectionSpacing)
    }

    private func sidebarRow(_ item: Section) -> some View {
        let isSelected = section == item
        return Button {
            section = item
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

    // MARK: - Содержимое

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                switch section {
                case .account: AccountSettingsTab()
                case .pbx: PBXSettingsTab()
                case .incoming: IncomingCallSettingsTab()
                case .macros: DTMFSettingsTab()
                case .queues: QueueSettingsTab()
                case .history: CallHistorySettingsTab()
                case .diagnostics: DiagnosticsTab()
                case .access: AdministrationTab()
                case .maintenance: MaintenanceTab()
                }
            }
            .padding(.horizontal, Theme.Metrics.contentPadding)
            .padding(.bottom, Theme.Metrics.contentPadding)
            .padding(.top, Theme.Gap.titleToStatus)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Полоса прокрутки не отбирает ширину: иначе раздел с прокруткой и
            // раздел без неё получают разный отступ справа, и правый край
            // дёргается при переключении.
            //
            // Помощник стоит внутри прокрутки, а не на её фоне: `.background`
            // кладёт вью рядом со `NSScrollView`, а не под него, и поиск вверх
            // по иерархии до самой прокрутки не доходил — первый заход это и
            // показал, отступы остались разными.
            .compatBackground { ScrollOverlayScrollers() }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Несохранённое поразделно

    /// Разошлось ли содержимое раздела со снимком, снятым при входе.
    ///
    /// Сравнение поимённое, а не по всему `settings`: иначе точка загоралась бы
    /// у всех девяти разделов сразу и не сообщала бы ничего. Раздел
    /// «Обслуживание» своих настроек не имеет — его действия либо немедленные,
    /// либо ложатся в тот же черновик и зажигают точки там, где значения
    /// действительно разошлись.
    private func isDirty(_ item: Section) -> Bool {
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

    // MARK: - Низ окна

    private var footer: some View {
        HStack(spacing: Theme.Metrics.sectionSpacing) {
            CompatSymbol(
                name: model.hasUnsavedAdministrationChanges
                    ? "exclamationmark.triangle" : "lock.shield.fill"
            )
            .compatForeground(
                model.hasUnsavedAdministrationChanges
                    ? Theme.Palette.unsaved : Theme.Palette.textSecondary
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(
                    model.hasUnsavedAdministrationChanges
                        ? "Есть несохранённые изменения" : "Изменений нет"
                )
                Text(
                    model.hasUnsavedAdministrationChanges
                        ? "Пока не нажато «Сохранить», на диск не записано ничего."
                        : "Настройки этой машины: \(model.adminAccess.management.title.lowercased())."
                )
                .font(.footnote)
                .compatForeground(.secondary)
            }

            Spacer()

            Button("Отменить") {
                model.cancelAdministration()
                closeWindow()
            }
            .compatHelp("Вернуть настройки к тому, что было при входе")

            Button("Сохранить") { isConfirmingSave = true }
                .compatProminentButtonStyle()
                .disabled(!model.hasUnsavedAdministrationChanges)
        }
        // Полоса идёт во всю ширину окна, но её содержимое начинается там же,
        // где плашки разделов: значок состояния под сайдбаром висел бы на
        // отдельном левом крае, а «один левый край у страницы» — правило с
        // этапа 2.
        .padding(.leading, Theme.Metrics.adminSidebarWidth
            + Theme.Metrics.sectionSpacing * 2
            + Theme.Metrics.contentPadding)
        .padding(.trailing, Theme.Metrics.contentPadding)
        .padding(.vertical, Theme.Metrics.sectionSpacing)
        .frame(maxWidth: .infinity)
        // Предупреждение дублируется на сохранении — того же содержания, что и
        // на входе. Намеренно: между входом и нажатием проходит вся настройка
        // рабочего места, и к этому моменту прочитанное на входе уже забыто.
        .alert(isPresented: $isConfirmingSave) {
            Alert(
                title: Text("Сохранить настройки?"),
                message: Text("""
                    Настройки этой машины станут локальными: их задаёт администратор, \
                    а не файл конфигурации. Сохранение будет записано в журнал.
                    """),
                primaryButton: .default(Text("Сохранить")) {
                    model.commitAdministration()
                    closeWindow()
                },
                secondaryButton: .cancel(Text("Не сохранять"))
            )
        }
    }

    /// Закрытие через цепочку ответчиков — тем же кодом, что открывал окно.
    /// Второго места, умеющего его закрывать, в приложении нет.
    private func closeWindow() {
        NSApp.sendAction(#selector(AppDelegate.closeAdministrationWindow(_:)), to: nil, from: nil)
    }
}
