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
            HStack(spacing: 0) {
                sidebar
                Divider()

                VStack(spacing: 0) {
                    content
                    Divider()
                    footer
                }
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
    }

    /// Единственный порог перестроения, считанный от ширины окна.
    ///
    /// Из ширины вычитается всё, что списку не достаётся: сайдбар, черта между
    /// ним и содержимым, поля по краям и отступы плашки раздела. Иначе порог
    /// сработал бы раньше, чем список действительно получил бы место.
    private func columns(forWindowWidth width: CGFloat) -> Int {
        let available = width
            - Theme.Metrics.adminSidebarWidth
            - 1
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
            case .macros: "Обслуживание вызова"
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
                        .font(.footnote)
                        .compatForeground(Theme.Palette.textSecondary)
                        .padding(.horizontal, Theme.Metrics.sectionSpacing)
                        .padding(.top, Theme.Metrics.sectionSpacing)
                        .padding(.bottom, Theme.Metrics.hairSpacing)
                }

                sidebarRow(item)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Metrics.elementSpacing)
        .padding(.bottom, Theme.Metrics.contentPadding)
        .padding(.top, Theme.Gap.titleToStatus)
        .frame(width: Theme.Metrics.adminSidebarWidth, alignment: .leading)
        .compatBackground {
            // Материал `.sidebar` есть с 10.11, то есть работает и на Catalina.
            // Разница со свежими системами будет — там у сайдбара своё
            // скругление и плавающий край, — и она принятая: то же решение, что
            // по остальным поверхностям приложения.
            CompatMaterial(material: .sidebar, blending: .behindWindow, cornerRadius: 0)
                .compatIgnoreSafeArea()
        }
    }

    private func sidebarRow(_ item: Section) -> some View {
        Button {
            section = item
        } label: {
            HStack(spacing: Theme.Metrics.elementSpacing) {
                CompatSymbol(name: item.symbol, size: Theme.Icon.large)
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
            .padding(.horizontal, Theme.Metrics.elementSpacing)
            .frame(height: Theme.Metrics.adminSidebarRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .compatBackground {
                // Выделение — заливка, а не акцентный стиль кнопки: акцентного
                // стиля на Catalina нет вовсе, и прежний бар разделов обозначал
                // выбранное галочкой вместо значка. С плашкой значок остаётся
                // значком.
                RoundedRectangle(cornerRadius: Theme.Metrics.adminSidebarRadius)
                    .fill(section == item ? Theme.Palette.sidebarSelection : .clear)
            }
        }
        .buttonStyle(.plain)
        .hoverHighlight(
            cornerRadius: Theme.Metrics.adminSidebarRadius,
            isEnabled: section != item
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
                || now.siteAddresses != snapshot.siteAddresses
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
        .padding(.horizontal, Theme.Metrics.contentPadding)
        .padding(.vertical, Theme.Metrics.sectionSpacing)
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
