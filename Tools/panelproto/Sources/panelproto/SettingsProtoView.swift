import AppKit
import SwiftUI

/// Макет настроек менеджера — этап 2 плана по интерфейсу.
///
/// Собран, чтобы посмотреть на решение, а не чтобы работать: контролы живут на
/// местном состоянии и ни на что не влияют.
///
/// **Что проверяется этим макетом.** Три вещи, и все три словами не решаются:
///
///   - **влезает ли одной страницей.** Вкладки из плана отменены: после того
///     как макросы, профили и площадка ушли администратору, у менеджера
///     осталось четыре раздела, и один из них — единственный переключатель
///     темы. Четыре вкладки на такой объём — оформление ради оформления;
///   - **читается ли мелкий текст на прозрачном фоне.** В панели мелкого
///     текста почти нет, здесь он основной жанр: пояснения к самопроверке, к
///     логам, предупреждение о разных устройствах. Замер по снимку этого окна
///     и есть ответ;
///   - **не разъезжается ли системный контрол с прозрачной поверхностью.**
///     `Picker` и `Toggle` рисует система, и рисует она их для непрозрачного
///     окна настроек.
///
/// **Почему не `Form`.** Сгруппированная форма ставит непрозрачные плашки
/// секций, и сквозь них материала не видно — то есть ровно та прозрачность, за
/// которой всё затевалось, пропадает. Отсюда ручная раскладка в две колонки:
/// подпись слева фиксированной шириной, контрол справа.
struct SettingsProtoView: View {

    @State private var input = "Системный по умолчанию"
    @State private var output = "AirPods Pro"
    @State private var gainControl = true
    @State private var releasesDevice = true
    @State private var ringtoneEnabled = true
    @State private var ringtoneVolume = 0.6
    @State private var ringtoneOutput = "системное устройство"
    @State private var appearance = "Как в системе"

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsTokens.sectionGap) {
            titleBar
            audio
            ringtone
            appearanceSection
            support
            administration
        }
        .padding(.horizontal, SettingsTokens.windowPadding)
        .padding(.bottom, SettingsTokens.windowPadding)
        // Ширина своя, высота — по содержимому: окно подстроится под неё, и
        // материал накроет ровно столько, сколько есть окна. Растягивать здесь
        // нельзя: тогда вёрстка окажется ниже окна, и сверху останется дыра.
        .frame(width: SettingsTokens.windowWidth, alignment: .leading)
        .settingsSurface()
        // Без этого материал не заходит под полосу заголовка: при
        // `.fullSizeContentView` окно отдаёт вёрстке всю высоту, но SwiftUI
        // сам отступает от полосы безопасной зоной — и фон отступает вместе с
        // содержимым. У непрозрачного окна это незаметно, у прозрачного там
        // дыра, и светофор оказывается на чужих вкладках.
        .ignoresSafeArea()
    }

    /// Полосу заголовка рисует вёрстка, а не окно (`titleVisibility = .hidden`),
    /// и ровно по той же причине, что в панели: у окна с прозрачным фоном
    /// системная полоса остаётся без материала, и светофор с названием повисают
    /// над рабочим столом — видно чужие вкладки прямо под кнопками.
    ///
    /// Название по центру, как у обычного окна macOS. Оно же не даёт светофору
    /// висеть в пустоте: без надписи три кнопки на пустом стекле читаются как
    /// оторванные от окна.
    private var titleBar: some View {
        Text("Настройки EliteSIP")
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: SettingsTokens.titleBarInset)
    }

    // MARK: - Звук

    private var audio: some View {
        SettingsSection("Звук") {
            SettingsRow("Микрофон") {
                Picker("", selection: $input) {
                    Text("Системный по умолчанию").tag("Системный по умолчанию")
                    Text("MacBook Pro Microphone").tag("MacBook Pro Microphone")
                }
                .labelsHidden()
            }
            // Что уйдёт в звонок на самом деле. «Системный по умолчанию» — это
            // не устройство, а правило, и правило меняет ответ, когда меняются
            // наушники. Оператор спрашивает «меня будет слышно через что», и
            // название правила на этот вопрос не отвечает.
            if input.hasPrefix("Системн") {
                SettingsResolved("в звонке: AirPods Pro")
            }

            SettingsRow("Наушники") {
                Picker("", selection: $output) {
                    Text("Системные по умолчанию").tag("Системные по умолчанию")
                    Text("AirPods Pro").tag("AirPods Pro")
                }
                .labelsHidden()
            }
            if output.hasPrefix("Системн") {
                SettingsResolved("в звонке: AirPods Pro")
            }

            // Появляется только когда обе стороны заданы явно и разными. Если
            // хоть одна отдана системе, агрегат не собирается, эхоподавление
            // работает, и говорить не о чем.
            //
            // Текст не обещает эха: его не будет ни в наушниках, ни в
            // гарнитуре — там микрофон акустически развязан с динамиком. Эхо
            // случается на колонках, и сказано именно так.
            if isDeviceMismatch {
                SettingsNote(
                    """
                    Разные устройства: системного эхоподавления не будет. \
                    На колонках собеседник услышит себя, в наушниках — нет.
                    """
                )
            }

            SettingsToggle("Автоматическая регулировка усиления", isOn: $gainControl)
            SettingsToggle("Отпускать наушники между звонками", isOn: $releasesDevice)

            SettingsDivider()

            SettingsNote(
                """
                Самопроверка: пять секунд записи и сразу воспроизведение — через \
                тот же тракт, что и разговор.
                """
            )
            SettingsButtons {
                Button("Записать и прослушать") {}
            }
        }
    }

    /// Обе стороны заданы явно и разными — тогда движок соберёт агрегатное
    /// устройство, а `VoiceProcessingIO` агрегаты не принимает.
    private var isDeviceMismatch: Bool {
        !input.hasPrefix("Системн") && !output.hasPrefix("Системн") && input != output
    }

    // MARK: - Звонок

    private var ringtone: some View {
        SettingsSection("Звонок") {
            SettingsToggle("Проигрывать рингтон", isOn: $ringtoneEnabled)

            SettingsRow("Громкость") {
                Slider(value: $ringtoneVolume, in: 0...1)
                    .frame(maxWidth: 220)
            }

            SettingsRow("Играть в") {
                Picker("", selection: $ringtoneOutput) {
                    Text("системное устройство").tag("системное устройство")
                    Text("устройство разговора").tag("устройство разговора")
                }
                .labelsHidden()
            }

            SettingsRow("Звук") {
                Text("Стандартный")
                    .foregroundStyle(.secondary)
            }

            SettingsButtons {
                Button("Выбрать файл…") {}
                Button("Стандартный") {}
                    .disabled(true)
                Button("Прослушать") {}
            }
        }
        .opacity(ringtoneEnabled ? 1 : SettingsTokens.disabledOpacity)
    }

    // MARK: - Оформление

    private var appearanceSection: some View {
        SettingsSection("Оформление") {
            SettingsRow("Тема") {
                Picker("", selection: $appearance) {
                    Text("Светлая").tag("Светлая")
                    Text("Тёмная").tag("Тёмная")
                    Text("Как в системе").tag("Как в системе")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }
        }
    }

    // MARK: - Техподдержка

    private var support: some View {
        SettingsSection("Техподдержка") {
            SettingsNote(
                """
                Архив с журналом и сведениями о системе. Соберите его и отправьте \
                в поддержку — по нему разбирают, что случилось со звонком.
                """
            )
            SettingsButtons {
                Button("Собрать логи") {}
                Button("Исправить сеть") {}
            }

            // Строка площадки только на чтение: переключать её вручную больше
            // нельзя, а называть в поддержке — надо.
            SettingsRow("Площадка") {
                Text("Офис · 192.168.1.2 · определено автоматически")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
    }

    // MARK: - Дверь в «Управление»

    private var administration: some View {
        HStack(spacing: SettingsTokens.rowSpacing) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text("Настройками управляет администратор")
                Text("Аккаунты, макросы, защита от автокликеров и диагностика")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: SettingsTokens.rowSpacing)

            Button("Управление \u{203A}") {}
        }
        .padding(SettingsTokens.blockPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsBlock()
    }
}

// MARK: - Токены макета

/// Числа взяты из `Theme` приложения, а не подобраны заново.
///
/// Ширина — единственное новое: 560 из плана. Панель узкая, потому что висит
/// поверх CRM весь день; настройки открывают на минуту, и жать их незачем.
enum SettingsTokens {
    static let windowWidth: CGFloat = 560
    static let windowPadding: CGFloat = 12
    /// Полосу заголовка рисует окно, высота её системная. Здесь она нужна
    /// числом, потому что содержимое уезжает под неё; в приложении то же
    /// значение сообщает вёрстке само окно.
    static let titleBarInset: CGFloat = 28
    /// Воздух между полосой заголовка и первым разделом. Меньше шкалы, и
    /// намеренно: он держит светофор, а не отделяет от него.
    static let hairGap: CGFloat = 4
    static let sectionGap: CGFloat = 12
    static let blockPadding: CGFloat = 12
    static let rowSpacing: CGFloat = 8
    static let rowGap: CGFloat = 8
    /// Подпись всегда одной ширины: иначе контролы соседних строк не стоят в
    /// колонку, и глаз ищет их заново на каждой.
    static let labelColumn: CGFloat = 150
    static let surfaceRadius: CGFloat = 12
    static let disabledOpacity: Double = 0.57
}

// MARK: - Кирпичи раскладки

private struct SettingsSection<Content: View>: View {

    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsTokens.rowGap) {
            // Заголовок над плашкой, а не внутри: так он читается как имя
            // группы, а не как её первая строка.
            Text(title)
                .font(.headline)

            VStack(alignment: .leading, spacing: SettingsTokens.rowGap) {
                content
            }
            .padding(SettingsTokens.blockPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsBlock()
        }
    }
}

private struct SettingsRow<Control: View>: View {

    let title: String
    @ViewBuilder let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SettingsTokens.rowSpacing) {
            Text(title)
                .frame(width: SettingsTokens.labelColumn, alignment: .trailing)
            control
            Spacer(minLength: 0)
        }
    }
}

private struct SettingsToggle: View {

    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        HStack(spacing: SettingsTokens.rowSpacing) {
            // Выключатель встаёт в ту же колонку, где у прочих строк контрол:
            // подпись у него своя и слева не дублируется.
            Color.clear.frame(width: SettingsTokens.labelColumn, height: 1)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
            Spacer(minLength: 0)
        }
    }
}

private struct SettingsNote: View {

    let text: String
    var isAlarming = false

    init(_ text: String, isAlarming: Bool = false) {
        self.text = text
        self.isAlarming = isAlarming
    }

    var body: some View {
        HStack(alignment: .top, spacing: SettingsTokens.rowSpacing) {
            Color.clear.frame(width: SettingsTokens.labelColumn, height: 1)
            Text(text)
                .font(.footnote)
                .foregroundStyle(isAlarming ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Чем «системное умолчанию» обернётся в звонке. Не подпись и не пояснение:
/// это значение, просто вычисленное, — поэтому стоит в колонке контрола и
/// набрано как значение.
private struct SettingsResolved: View {

    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: SettingsTokens.rowSpacing) {
            Color.clear.frame(width: SettingsTokens.labelColumn, height: 1)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

private struct SettingsButtons<Content: View>: View {

    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: SettingsTokens.rowSpacing) {
            Color.clear.frame(width: SettingsTokens.labelColumn, height: 1)
            content
            Spacer(minLength: 0)
        }
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.vertical, 2)
    }
}

// MARK: - Поверхности

private extension View {

    /// Фон окна: то же, что у панели после 6 августа — системный материал без
    /// своей подкраски.
    func settingsSurface() -> some View {
        background {
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 0))
            } else {
                BehindWindowMaterial(cornerRadius: 0)
            }
        }
    }

    /// Плашка группы. Тот же слабый слой, что у клавиш панели: он полупрозрачен,
    /// и материал под ним остаётся виден — иначе окно было бы стеклянным только
    /// по краям.
    func settingsBlock() -> some View {
        background {
            RoundedRectangle(cornerRadius: SettingsTokens.surfaceRadius)
                .fill(Color.primary.opacity(0.06))
        }
    }
}
