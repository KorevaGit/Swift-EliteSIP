import AppKit
import SwiftUI

/// Правая половина окна настроек: открытый раздел и полоса низа.
///
/// Собрана тем же рецептом, что и `AdministrationContentView`, вплоть до
/// выравнивания по плавающей вставке сайдбара: окна отличаются содержимым, а не
/// устройством. Разборы общих решений — почему полоса низа принадлежит этой
/// половине, а не окну, и почему поля вставки приходится читать у AppKit —
/// записаны там и здесь не повторяются.
///
/// Своего здесь два:
///
/// - **Полоса низа не про сохранение.** Менеджерские настройки применяются
///   сразу, и кнопок «Сохранить» с «Отменить» тут нет и быть не может. Полосу
///   занимает дверь в «Управление» — единственное в этом окне действие, которое
///   относится к окну целиком, а не к открытому разделу.
/// - **Столбцов всегда один.** Порог перестроения в два столбца
///   (`settingsListColumns`) остаётся значением по умолчанию: списков, которые
///   от ширины выигрывают, в менеджерских разделах нет — они все уехали
///   администратору.
struct ManagerContentView: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: ManagerRouter

    /// Показывать ли окно ввода административного пароля.
    @State private var isAskingForPassword = false

    /// Корпус, в котором собрана эта половина. Не `Theme.Chrome`: см.
    /// `windowUsesGlass`.
    @Environment(\.windowUsesGlass) private var usesGlass

    /// Поля плавающей вставки сайдбара — по ним выравнивается эта половина.
    /// Величина системная и на прежних версиях macOS равна нулю; подробности —
    /// у `SidebarInsetReader`.
    @State private var sidebarInset: (top: CGFloat, bottom: CGFloat) = (0, 0)

    var body: some View {
        VStack(spacing: 0) {
            content
            footer
        }
        // Верх и низ — по вставке сайдбара, а не по краю окна: поля вставки
        // достаются только сайдбару, и без этого правая половина начинается
        // выше левой и кончается ниже её.
        .padding(.top, sidebarInset.top)
        .padding(.bottom, sidebarInset.bottom)
        .compatBackground {
            SidebarInsetReader { top, bottom in sidebarInset = (top, bottom) }
        }
        // Колонка подписей — менеджерские 72: подписи здесь короткие
        // («Громкость», «Микрофон»), и колонка «Управления» в 132 точки
        // отодвинула бы контролы от левого края на пустое место.
        .environment(\.settingsLabelColumn, Theme.Metrics.settingsLabelColumn)
        // Потолок ширины строк. Раньше его роль играла фиксированная ширина
        // окна; теперь окно тянется, а строки — нет.
        .environment(\.settingsRowMaxWidth, Theme.Metrics.settingsContentMaxWidth)
        // Заголовок окна — имя раздела, как у «Управления» и у истории. В самой
        // полосе он не показывается (`titleVisibility`): там он повторял бы
        // выбранную строку сайдбара в полутора сантиметрах левее. Нужен он в
        // переключателе окон и в Mission Control — там сайдбара не видно.
        .compatBackground { WindowTitle(title: router.section.title) }
        .sheet(isPresented: $isAskingForPassword) {
            AdminUnlockView(isPresented: $isAskingForPassword)
                .environmentObject(model)
        }
    }

    // MARK: - Раздел

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
                switch router.section {
                case .audio: AudioTab()
                case .ringtone: RingtoneTab()
                case .appearance: AppearanceTab()
                case .support: SupportTab()
                }
            }
            .padding(.horizontal, Theme.Metrics.contentPadding)
            .padding(.bottom, Theme.Metrics.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Полоса прокрутки не отбирает ширину: иначе раздел с прокруткой и
            // раздел без неё получают разный отступ справа, и правый край
            // дёргается при переключении.
            .compatBackground { ScrollOverlayScrollers() }
        }
        // Мелкий размер управляющих элементов на всю страницу — то же решение,
        // что и на прежней странице: обычный `Picker` занимает 22 точки,
        // мелкий — 17, а таких строк в одном «Звуке» полдюжины.
        .controlSize(.small)
        .compatOwnTopInset(Theme.Metrics.contentTopInset(glass: usesGlass))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Полоса низа

    /// Дверь в закрытую часть настроек.
    ///
    /// Раньше она была последним блоком страницы — «пусть менеджер её найдёт,
    /// если понадобится, а не спотыкается о неё, меняя громкость». С разбором
    /// страницы на разделы у последнего блока не стало места: приписать дверь к
    /// «Техподдержке» значило бы объявить её частью раздела, а в сайдбар она не
    /// годится — за ней не раздел, а другое окно.
    ///
    /// Полоса низа — честное для неё место: там же, где в «Управлении» стоят
    /// действия над всем окном. Цену стоит назвать: дверь стала видна из любого
    /// раздела, а не с одного места внизу страницы. Заметной она от этого не
    /// становится — кнопка обычная, а не акцентная, и подпись предупреждает о
    /// пароле до нажатия, а не после.
    private var footer: some View {
        HStack(spacing: Theme.Metrics.sectionSpacing) {
            CompatSymbol(name: "lock.shield.fill")
                .compatForeground(Theme.Palette.textSecondary)

            VStack(alignment: .leading, spacing: Theme.Metrics.hairSpacing) {
                Text("Режим администратора")
                // Предупреждение, а не объяснение: перечислять, что лежит за
                // дверью, менеджеру незачем — он туда не идёт; а вот знать, что
                // дверь заперта, надо до нажатия, иначе запрос пароля выглядит
                // отказом.
                Text("Требуется пароль")
                    .font(.footnote)
                    .compatForeground(.secondary)
            }

            Spacer()

            // Шеврон — потому что кнопка ведёт в другое окно. Оно и заменяет
            // собой это: «Управление» закрывает настройки, а не встаёт рядом.
            Button("Управление \u{203A}") { isAskingForPassword = true }
        }
        .controlSize(.small)
        .padding(.horizontal, Theme.Metrics.contentPadding)
        .padding(.vertical, Theme.Metrics.sectionSpacing)
    }
}
