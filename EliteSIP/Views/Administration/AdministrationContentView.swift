import AppKit
import SwiftUI

/// Правая половина «Управления»: открытый раздел и полоса низа.
///
/// Отдельная вью, а не половина одного дерева: окно собрано системным
/// `NSSplitViewController`, и содержимое живёт в своём контроллере, рядом с
/// сайдбаром, а не внутри общей раскладки.
///
/// **Полоса низа принадлежит этой половине, а не окну.** Был заход растянуть её
/// во всю ширину — тогда сайдбар обрывался выше неё, и у окна получалось два
/// разных низа. В Finder и Music сайдбар идёт от полосы заголовка до самого низа
/// окна, а всё, что снизу, живёт в содержимом; теперь так же.
struct AdministrationContentView: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: AdministrationRouter

    @State private var isConfirmingSave = false

    /// Корпус, в котором собрана эта половина. Не `Theme.Chrome`: см.
    /// `windowUsesGlass`.
    @Environment(\.windowUsesGlass) private var usesGlass

    /// Поля плавающей вставки сайдбара — по ним выравнивается эта половина.
    ///
    /// Их сообщает `SidebarInsetReader`, потому что величина системная: на
    /// macOS 26 сайдбар — вставка со скруглёнными углами и полями, на прежних
    /// версиях полей нет вовсе, и там оба числа останутся нулями.
    @State private var sidebarInset: (top: CGFloat, bottom: CGFloat) = (0, 0)

    var body: some View {
        // Ширина берётся у своей половины, а не у окна: контроллер содержимого
        // и так знает ровно ту ширину, которую списку отдали, — вычитать
        // сайдбар и поля вручную больше не нужно.
        GeometryReader { proxy in
            VStack(spacing: 0) {
                content
                footer
            }
            .environment(\.settingsListColumns, columns(forContentWidth: proxy.size.width))
            // Верх и низ — по вставке сайдбара, а не по краю окна. Без этого
            // правая половина и начинается выше левой, и кончается ниже её:
            // поля вставки достаются только сайдбару.
            .padding(.top, sidebarInset.top)
            .padding(.bottom, sidebarInset.bottom)
            .compatBackground {
                SidebarInsetReader { top, bottom in sidebarInset = (top, bottom) }
            }
        }
        // Колонка подписей шире менеджерских 72: здесь «Отображаемое имя» и
        // «Время регистрации», а не «Громкость». На 72 каждая вторая подпись
        // переносилась бы в две строки.
        .environment(\.settingsLabelColumn, Theme.Metrics.adminLabelColumn)
        // Потолок ширины у строк «подпись — управление». Без него растяжимое
        // окно даёт поле ввода домена длиной во весь монитор, а пояснение —
        // строкой в полтораста знаков; и то и другое читается как сбой, а не
        // как простор. Настоящие списки потолка не знают и растягиваются.
        .environment(\.settingsRowMaxWidth, Theme.Metrics.adminContentMaxWidth)
        // Заголовок окна — имя раздела, как у Finder имя текущей папки.
        //
        // Постоянное «Управление EliteSIP» отвечало на «какое это окно», но в
        // переключателе окон и в Mission Control этого мало: разделов девять, и
        // человек ищет тот, где он был. Тем же `WindowTitle`, что у истории с
        // именем профиля, — второго способа менять заголовок в приложении нет.
        //
        // В самой полосе заголовка имя не показывается (`titleVisibility`): над
        // содержимым оно повторяло выбранную строку сайдбара, стоящую в
        // полутора сантиметрах левее. Здесь оно ставится ради переключателя
        // окон — там сайдбара не видно.
        .compatBackground { WindowTitle(title: router.section.title) }
    }

    /// Единственный порог перестроения списков в два столбца.
    ///
    /// Один порог, а не плавная резина: у растяжимого окна иначе исчезает сам
    /// метод проверки — «правильных» чисел становится бесконечно много, и
    /// замерить нечего.
    private func columns(forContentWidth width: CGFloat) -> Int {
        let available = width
            - Theme.Metrics.contentPadding * 2
            - Theme.Metrics.sectionSpacing * 2
        return available >= Theme.Metrics.adminTwoColumnThreshold ? 2 : 1
    }

    // MARK: - Раздел

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                switch router.section {
                case .account: AccountSettingsTab()
                case .presets: PresetsTab()
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
        // Отступ сверху меньше сайдбарного: там его высоту задаёт светофор,
        // здесь светофора нет, и содержимое встаёт с ним на одну линию.
        // Почему он вообще свой, а не системный, — см.
        // `Theme.Metrics.contentTopInset`.
        .compatOwnTopInset(Theme.Metrics.contentTopInset(glass: usesGlass))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Полоса низа

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
        .controlSize(.small)
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
