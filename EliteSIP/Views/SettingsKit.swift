import SwiftUI

/// Кирпичи раскладки настроек, общие для менеджерского окна и «Управления».
///
/// До этапа 5 они лежали приватно внутри `ManagerSettingsView`, и это работало,
/// пока страница была одна. С появлением второго окна на тех же правилах копия
/// означала бы расхождение — ровно то, из-за которого в «Управлении» до сих пор
/// висел прежний текст предупреждения про эхо, переписанный у менеджера ещё в
/// этапе 2.
///
/// Единственное, что различается у двух окон, — ширина колонки подписей:
/// менеджерские 72 точки посчитаны по «Громкость» и «Микрофон», а здесь есть
/// «Отображаемое имя» и «Добавочный комнаты». Поэтому колонка приезжает из
/// окружения, а не зашита в компонент.

// MARK: - Колонка подписей

private struct SettingsLabelColumnKey: EnvironmentKey {
    static let defaultValue: CGFloat = Theme.Metrics.settingsLabelColumn
}

extension EnvironmentValues {

    /// Ширина колонки подписей. Одна на всё окно: иначе контролы соседних строк
    /// не стоят в колонку, и глаз ищет их заново на каждой строке.
    var settingsLabelColumn: CGFloat {
        get { self[SettingsLabelColumnKey.self] }
        set { self[SettingsLabelColumnKey.self] = newValue }
    }
}

private struct SettingsRowMaxWidthKey: EnvironmentKey {
    /// Без потолка: менеджерская страница фиксированной ширины, и ограничивать
    /// там нечего.
    static let defaultValue: CGFloat = .infinity
}

extension EnvironmentValues {

    /// Потолок ширины у строк «подпись — управление».
    ///
    /// Нужен растяжимому окну «Управление»: без него поле ввода домена
    /// растягивается на весь монитор, а пояснение превращается в строку в
    /// полтораста знаков. Настоящие списки — профили, макросы, очереди, шаги
    /// стука — потолка не знают: им ширина идёт на пользу.
    var settingsRowMaxWidth: CGFloat {
        get { self[SettingsRowMaxWidthKey.self] }
        set { self[SettingsRowMaxWidthKey.self] = newValue }
    }
}

private struct SettingsListColumnsKey: EnvironmentKey {
    static let defaultValue: Int = 1
}

extension EnvironmentValues {

    /// В сколько столбцов раскладывать упорядоченные списки.
    ///
    /// Задаётся окном по замеренной ширине контентной области, а не каждым
    /// списком по своей: иначе профили и очереди перестроились бы на разной
    /// ширине, и порог, который мы обещали замерить, стал бы двумя порогами.
    var settingsListColumns: Int {
        get { self[SettingsListColumnsKey.self] }
        set { self[SettingsListColumnsKey.self] = newValue }
    }
}

// MARK: - Группа

/// Заголовок группы и плашка под её строками.
///
/// Заголовок над плашкой, а не внутри: так он читается как имя группы, а не как
/// её первая строка.
struct SettingsSection<Content: View>: View {

    private let title: Text
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = Text(title)
        self.content = content()
    }

    /// Заголовок, собранный в рантайме, — переводить нечего.
    init(verbatim title: some StringProtocol, @ViewBuilder content: () -> Content) {
        self.title = Text(title)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.tightSpacing) {
            title
                .font(Font.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: Theme.Metrics.elementSpacing) {
                content
            }
            // Кегль задаётся блоку, а не каждой строке: так под него попадает и
            // то, о чём легко забыть, — значение рядом с ползунком, имя файла
            // рингтона, подписи кнопок.
            .font(.callout)
            .padding(Theme.Metrics.sectionSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Тот же слабый слой, что у клавиш панели: он полупрозрачен, и
            // материал под ним остаётся виден — иначе окно было бы стеклянным
            // только по краям.
            .themedControlSurface(cornerRadius: Theme.Radius.surface)
        }
    }
}

// MARK: - Строки

/// Строка «подпись — контрол».
struct SettingsRow<Control: View>: View {

    @Environment(\.settingsLabelColumn) private var labelColumn
    @Environment(\.settingsRowMaxWidth) private var maxWidth

    private let title: Text
    @ViewBuilder let control: Control

    init(_ title: LocalizedStringKey, @ViewBuilder control: () -> Control) {
        self.title = Text(title)
        self.control = control()
    }

    /// Подпись, собранная в рантайме, — переводить нечего.
    init(verbatim title: some StringProtocol, @ViewBuilder control: () -> Control) {
        self.title = Text(title)
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Metrics.elementSpacing) {
            title
                .frame(width: labelColumn, alignment: .trailing)
            control
            Spacer(minLength: 0)
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
    }
}

/// Выключатель. Подпись у него своя, поэтому левая колонка пустая: иначе
/// подпись стояла бы дважды.
struct SettingsToggleRow: View {

    private let title: Text
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, isOn: Binding<Bool>) {
        self.title = Text(title)
        self._isOn = isOn
    }

    /// Подпись, собранная в рантайме, — переводить нечего.
    init(verbatim title: some StringProtocol, isOn: Binding<Bool>) {
        self.title = Text(title)
        self._isOn = isOn
    }

    var body: some View {
        SettingsIndented {
            // Во всю оставшуюся ширину: тогда подпись начинается от колонки
            // контролов, как у всех прочих строк, а тумблер встаёт по правому
            // краю блока — и все тумблеры страницы стоят на одной вертикали.
            //
            // Подпись переносится, а не обрезается: «Автоматическая регулировка
            // усиле…» не сообщает ничего, а укорачивать саму настройку ради
            // двадцати точек ширины — менять смысл под вёрстку.
            Toggle(isOn: $isOn) {
                // Ширину забирает подпись, а не тумблер: иначе у переносящейся
                // подписи тумблер прижимается к ней вплотную и уезжает с той
                // вертикали, на которой стоят остальные.
                title
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .compatSwitchToggle()
        }
    }
}

/// Пояснение или состояние — мелким, во второй колонке.
struct SettingsNote: View {

    private let text: Text
    var isAlarming = false

    init(_ text: LocalizedStringKey, isAlarming: Bool = false) {
        self.text = Text(text)
        self.isAlarming = isAlarming
    }

    /// Пояснение, собранное в рантайме, — переводить нечего.
    init(verbatim text: some StringProtocol, isAlarming: Bool = false) {
        self.text = Text(text)
        self.isAlarming = isAlarming
    }

    /// От колонки контролов, как всё остальное.
    ///
    /// Был заход пустить пояснения во всю ширину блока — ради высоты, когда
    /// окно не влезало в экран. Экономия вышла, но страница расслоилась на два
    /// левых края: подписи и контролы по одной вертикали, пояснения по другой.
    /// После сжатия окна высота перестала быть проблемой, и цена оказалась не
    /// нужна.
    var body: some View {
        SettingsIndented {
            text
                .font(.footnote)
                .compatForeground(isAlarming ? Theme.Palette.failure : Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Во что обернётся «системное по умолчанию». Не подпись и не пояснение: это
/// значение, просто вычисленное, — поэтому стоит в колонке контрола.
struct SettingsResolvedValue: View {

    private let text: Text

    init(_ text: LocalizedStringKey) { self.text = Text(text) }

    /// Значение, собранное в рантайме, — переводить нечего.
    init(verbatim text: some StringProtocol) { self.text = Text(text) }

    var body: some View {
        SettingsIndented {
            text
                .font(.footnote)
                .compatForeground(Theme.Palette.textSecondary)
        }
    }
}

struct SettingsButtonsRow<Content: View>: View {

    @ViewBuilder let content: Content

    var body: some View {
        SettingsIndented {
            HStack(spacing: Theme.Metrics.elementSpacing) {
                content
            }
        }
    }
}

/// Всё, у чего нет своей подписи, всё равно начинается от колонки контролов:
/// иначе страница расслаивается на два левых края.
struct SettingsIndented<Content: View>: View {

    @Environment(\.settingsLabelColumn) private var labelColumn
    @Environment(\.settingsRowMaxWidth) private var maxWidth

    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Metrics.elementSpacing) {
            Color.clear.frame(width: labelColumn, height: 1)
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
    }
}

/// Черта между устройствами и самопроверкой.
///
/// Не `Divider`: внутри `HStack` он становится вертикальным и схлопывается в
/// чёрточку. Здесь нужна линия поперёк, поэтому она задана прямоугольником.
struct SettingsDivider: View {

    @Environment(\.settingsLabelColumn) private var labelColumn

    var body: some View {
        HStack(spacing: Theme.Metrics.elementSpacing) {
            Color.clear.frame(width: labelColumn, height: 1)
            Rectangle()
                .fill(Theme.Palette.textTertiary)
                .frame(height: 1)
        }
    }
}

// MARK: - Раскладка по столбцам

/// Раскладывает однородные строки в один или два столбца по ширине окна.
///
/// Ни `Grid` (macOS 13), ни `LazyVGrid` (macOS 12) взять нельзя — принцип 5.
/// Разбиение на ряды вручную даёт одну и ту же раскладку на всех трёх системах
/// и стоит десяти строк.
///
/// Столбцов ровно два состояния, а не плавная резина: у растяжимого окна иначе
/// исчезает метод проверки, которым закрывались все прошлые этапы, — замерить
/// «правильную» ширину нельзя, когда их бесконечно много.
struct SettingsColumns<Element: Identifiable, Row: View>: View {

    @Environment(\.settingsListColumns) private var environmentColumns

    let items: [Element]

    /// Сколько столбцов вместо порога окна. `nil` — как решило окно.
    let override: Int?

    @ViewBuilder let row: (Element) -> Row

    init(
        _ items: [Element],
        columns override: Int? = nil,
        @ViewBuilder row: @escaping (Element) -> Row
    ) {
        self.items = items
        self.override = override
        self.row = row
    }

    private var columns: Int { override ?? environmentColumns }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.elementSpacing) {
            ForEach(chunks, id: \.first!.id) { chunk in
                HStack(alignment: .top, spacing: Theme.Metrics.sectionSpacing) {
                    ForEach(chunk) { item in
                        row(item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Добивка, когда в последнем ряду строк меньше, чем
                    // столбцов: без неё одинокая строка растягивается на всю
                    // ширину и выпадает из колонки.
                    if chunk.count < columns {
                        ForEach(0..<(columns - chunk.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private var chunks: [[Element]] {
        guard columns > 1 else { return items.map { [$0] } }
        return stride(from: 0, to: items.count, by: columns).map {
            Array(items[$0..<min($0 + columns, items.count)])
        }
    }
}

// MARK: - Упорядоченный список

/// Список строк, у которого значим порядок: макросы, очереди, шаги стука.
///
/// Один компонент на три места не ради экономии — это буквально одна и та же
/// вещь: строки с полями, добавление, удаление и перестановка. Три отдельных
/// списка пришлось бы потом сводить, и сводили бы их после того, как они уже
/// разошлись.
///
/// **Перестановка кнопками, а не перетаскиванием.** На Catalina перетаскивание
/// в списках SwiftUI работает ненадёжно, а ветка версий здесь означала бы два
/// разных поведения в том самом месте, которое принцип 5 велит держать
/// одинаковым. Списки тут короткие — тащить в них нечего, — зато кнопки
/// проверяются тестом.
struct SettingsOrderedList<Element: Identifiable, Row: View>: View {

    @Environment(\.settingsListColumns) private var columns

    @Binding var items: [Element]

    /// Что написано, когда список пуст. Пустое место без объяснения читается
    /// как незагрузившееся, а не как «здесь пока ничего нет».
    let emptyNote: LocalizedStringKey

    let addTitle: LocalizedStringKey

    /// Держать список в одну колонку, даже когда окно широкое.
    ///
    /// Ставится там, где порядок строк значим по существу: у макросов он задаёт
    /// раскладку кнопок на панели, у шагов стука — очерёдность пакетов. Живое
    /// окно показало, почему это важно: в двух столбцах список читается
    /// слева-направо, а кнопки «выше/ниже» двигают по одной позиции — и
    /// «выше» у правой строки уводит её в левый столбец. Порядок, который
    /// нельзя прочитать глазом, не порядок.
    ///
    /// Словарь очередей флага не ставит: там порядок ничего не решает, номер
    /// ищется поиском, и ширина списку идёт на пользу.
    var keepsSingleColumn = false

    /// Потолок числа строк, если он есть по существу. У макросов есть: высота
    /// панели выведена из их числа и обязана оставаться константой установки.
    var limit: Int?
    /// Почему потолок именно такой. Показывается, когда он достигнут.
    var limitNote: LocalizedStringKey?

    let makeElement: () -> Element
    @ViewBuilder let row: (Binding<Element>) -> Row

    private var isAtLimit: Bool {
        guard let limit else { return false }
        return items.count >= limit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.elementSpacing) {
            if items.isEmpty {
                SettingsNote(emptyNote)
            } else {
                rows
            }

            SettingsButtonsRow {
                Button(addTitle) { items.append(makeElement()) }
                    .disabled(isAtLimit)

                if isAtLimit, let limitNote {
                    Text(limitNote)
                        .font(.footnote)
                        .compatForeground(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var rows: some View {
        SettingsColumns(items, columns: keepsSingleColumn ? 1 : nil) { item in
            line(for: item)
        }
    }

    private func line(for item: Element) -> some View {
        HStack(alignment: .top, spacing: Theme.Metrics.elementSpacing) {
            row(binding(for: item.id))

            Spacer(minLength: 0)

            move(item, by: -1, symbol: .up, hint: "Выше")
            move(item, by: 1, symbol: .down, hint: "Ниже")

            Button {
                items.removeAll { $0.id == item.id }
            } label: {
                CompatSymbol(name: "trash", size: Theme.Icon.medium)
            }
            .buttonStyle(.borderless)
            .compatAccessibilityLabel("Удалить")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum Direction { case up, down }

    private func move(
        _ item: Element,
        by offset: Int,
        symbol: Direction,
        hint: String
    ) -> some View {
        let index = items.firstIndex { $0.id == item.id }
        let target = index.map { $0 + offset }
        let isPossible = target.map { items.indices.contains($0) } ?? false

        return Button {
            guard let index, let target, items.indices.contains(target) else { return }
            items.swapAt(index, target)
        } label: {
            // Тот же шеврон, что у выпадающих списков, развёрнутый вверх для
            // «выше». Своей стрелки в комплекте нет, и рисовать её ради двух
            // кнопок незачем: комплект дорисовывается в этапе 7, а форма здесь
            // читается однозначно.
            ChevronDown()
                .rotationEffect(.degrees(symbol == .up ? 180 : 0))
                .frame(width: Theme.Icon.medium, height: Theme.Icon.medium)
        }
        .buttonStyle(.borderless)
        .disabled(!isPossible)
        .compatAccessibilityLabel(hint)
    }

    /// Привязка ищется по `id`, а не по индексу.
    ///
    /// Индекс живёт ровно до первого удаления: `ForEach` перерисовывается уже
    /// после того, как строка исчезла из массива, и привязка по индексу успевает
    /// прочитать чужую строку или выйти за границы. Поиск по `id` этого не
    /// умеет, а свежий элемент в запасном ответе нужен на один кадр между
    /// удалением и перерисовкой.
    private func binding(for id: Element.ID) -> Binding<Element> {
        Binding(
            get: { items.first { $0.id == id } ?? makeElement() },
            set: { updated in
                guard let index = items.firstIndex(where: { $0.id == id }) else { return }
                items[index] = updated
            }
        )
    }
}

private struct WindowGlassKey: EnvironmentKey {
    /// По умолчанию — стекло: так выглядит окно на системе, под которую всё и
    /// считано. Значение всё равно проставляется явно при сборке окна.
    static let defaultValue = true
}

extension EnvironmentValues {

    /// В каком корпусе живёт эта половина окна — стеклянном или обычном.
    ///
    /// Общий для обоих окон с боковым списком: с переносом дизайна
    /// «Управления» на настройки менеджера половины у них устроены одинаково, и
    /// корпус им сообщается одинаково.
    ///
    /// Передаётся окном, а не читается вьюхами из `Theme.Chrome`, и это не
    /// формальность. Настройку «Без стекла» правят в самом окне, и глобальное
    /// значение меняется под уже собранным корпусом: вёрстка мгновенно
    /// перестраивалась под обычный вариант, а рамка оставалась стеклянной —
    /// список наезжал на светофор. Половина обязана верить тому корпусу, в
    /// котором её собрали, а не тому, что выбран на будущее.
    var windowUsesGlass: Bool {
        get { self[WindowGlassKey.self] }
        set { self[WindowGlassKey.self] = newValue }
    }
}
