import CallHistory
import SwiftUI

/// Окно «История звонков».
///
/// Отдельным окном, а не вкладкой панели (решение 3 августа 2026). Панель
/// шириной 270 точек и фиксированной высоты — это согласованное свойство
/// продукта, а не текущее состояние вёрстки: она висит поверх CRM весь рабочий
/// день. Список с фильтром и длительностями туда влезает только ценой
/// нечитаемых строк.
///
/// Кнопок удаления здесь нет, и это решение, а не недоделка. История нужна в
/// том числе как свидетельство при разборе жалобы, а свидетельство, которое
/// может убрать заинтересованная сторона, свидетельством не является. Записи
/// уходят по сроку хранения либо вместе с профилем, и то и другое — за паролем
/// администратора.
///
/// **Окно ограничено активным профилем жёстко** (решение 6 августа 2026).
/// «Все профили» здесь нет: если профили — это разные люди за одной машиной, то
/// граница между их звонками не удобство, а граница персональных данных.
/// Профиль назван в заголовке окна и меняется вместе с ним.
///
/// **Не `List`** — по той же причине, по которой в настройках нет `Form`:
/// системный список рисует непрозрачную подложку, и материал под ней не виден.
/// Терять нечего: выбор строки здесь не значит ничего — повтор набора живёт в
/// своей кнопке.
struct CallHistoryWindowView: View {

    @EnvironmentObject private var model: AppModel

    /// Область, которую снимает кнопка снимка. Ссылочный тип в `@State`, а не
    /// `@StateObject`: тот появился в macOS 11, а публиковать здесь нечего —
    /// якорь только держит вьюху и в перерисовках не участвует.
    @State private var snapshot = HistorySnapshotAnchor()

    /// Что сказать после снимка и сколько раз его уже делали.
    ///
    /// Счётчик нужен, чтобы отложенное скрытие гасило **своё** сообщение:
    /// без него второй снимок подряд гасился бы таймером первого — то есть
    /// через мгновение после нажатия.
    @State private var notice: String?
    @State private var noticeToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
            filterBar
            content
        }
        // Поля те же, что в панели и настройках: `contentPadding` по краям, а
        // сверху — `Gap.titleToStatus`, потому что сверху не край окна, а
        // полоса заголовка.
        .padding(.horizontal, Theme.Metrics.contentPadding)
        .padding(.bottom, Theme.Metrics.contentPadding)
        .padding(.top, Theme.Gap.titleToStatus)
        .frame(
            minWidth: Theme.Metrics.historyMinWidth,
            minHeight: Theme.Metrics.historyMinHeight
        )
        // Безопасную зону игнорирует только фон, а не раскладка: материал
        // обязан накрыть полосу заголовка, иначе светофор с названием повиснут
        // над чужим окном, — а содержимое должно встать под полосой само.
        .compatBackground {
            Color.clear
                .themedPanelSurface(cornerRadius: 0)
                .compatIgnoreSafeArea()
        }
        .compatBackground { WindowTitle(title: windowTitle) }
        // `onAppear` для перечитывания списка здесь нет намеренно: срез
        // перечитывает тот, кто открывает окно (`showCallHistoryWindow`), до
        // показа. Обновление после того, как строки уже разложены, уводило
        // прокрутку в конец — окно встречало оператора самым старым звонком.
    }

    /// Профиль в заголовке, потому что в строках его больше нет: список и так
    /// целиком принадлежит одному профилю, и повторять метку двести раз незачем.
    ///
    /// **Номер вместе с пометкой**, а не одна пометка: у двух профилей одного
    /// добавочного пометка — единственное различие, но у двух разных добавочных
    /// различие как раз номер, а пометки может не быть вовсе. Строится тем же
    /// `profileMenuTitle`, что и пункты списка в капсуле панели: заголовок окна
    /// обязан совпадать с тем, что оператор выбрал, слово в слово.
    private var windowTitle: String {
        let profile = model.profileMenuTitle(model.settings.profiles.active)
        return profile.isEmpty
            ? NSLocalizedString("История звонков", comment: "заголовок окна истории")
            : String(
                format: NSLocalizedString("История звонков — %@", comment: "заголовок окна истории с профилем"),
                profile
            )
    }

    // MARK: - Верх

    /// Фильтры и календарь одним центрированным рядом.
    ///
    /// Не `Picker(.segmented)`: сегментированный стиль рисует непрозрачную
    /// подложку и на стекле выглядит вырезанным из другого окна. Выбранное
    /// отмечено акцентом там, где он есть, и обычной рамкой на Catalina —
    /// `compatProminentButtonStyle` разбирает это одним местом на всё
    /// приложение.
    private var filterBar: some View {
        HStack(spacing: Theme.Metrics.elementSpacing) {
            Spacer()
            ForEach(CallHistoryStore.Filter.allCases, id: \.self) { item in
                Button {
                    model.historyFilter = item
                } label: {
                    HStack(spacing: Theme.Metrics.tightSpacing) {
                        FilterGlyph(filter: item)
                        // Подпись фильтра не ужимается никогда: «Пропущенн…»
                        // — это уже не название фильтра, а обещание, что за
                        // кнопкой что-то не поместилось. Ширину под весь ряд
                        // держит `historyMinWidth`.
                        Text(item.title).fixedSize()
                    }
                    .padding(.horizontal, Theme.Metrics.tightSpacing)
                    .padding(.vertical, Theme.Metrics.hairSpacing)
                }
                .compatProminentButtonStyle(model.historyFilter == item)
            }
            HistoryDayButton()
            HistorySnapshotButton(
                anchor: snapshot,
                // Тот же `profileMenuTitle`, что в заголовке окна и в капсуле
                // панели: снимок обязан быть подписан тем же именем, которое
                // оператор видел, когда его делал.
                profile: model.profileMenuTitle(model.settings.profiles.active),
                isEnabled: !model.historyRecords.isEmpty,
                onResult: show(notice:)
            )
            Spacer()
        }
        .font(.callout)
        // Мелкие кнопки, как на странице настроек. На обычном размере пять
        // кнопок в ряд оказывались самым заметным, что есть в окне, — заметнее
        // самих звонков, ради которых его открыли.
        .controlSize(.small)
        // При выключенной истории фильтровать нечего и никогда не будет:
        // работающие кнопки над пустым окном обещают, что где-то за ними записи
        // всё-таки есть.
        .disabled(!model.settings.history.isEnabled)
    }

    // MARK: - Список

    /// Список или пустое состояние — на одном и том же слабом слое.
    ///
    /// Слой один на оба случая намеренно: появляйся плашка только под
    /// строками, переключение фильтра на пустой набор меняло бы не содержимое
    /// окна, а его форму, — и это читается как поломка, а не как «здесь ничего
    /// нет».
    private var content: some View {
        Group {
            if model.historyRecords.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedControlSurface(cornerRadius: Theme.Radius.surface)
        // Якорь снимка — фоном плашки, потому что снимается ровно она.
        .compatBackground { HistorySnapshotArea(anchor: snapshot) }
        // Сообщение о снимке — поверх списка и снизу, где его не закроет рука с
        // мышью, идущая к кнопке наверху. В кадр оно не попадает: снимок
        // собирается в момент нажатия, до того как сообщение появилось.
        .compatOverlay {
            if let notice {
                VStack {
                    Spacer()
                    Text(notice)
                        .font(.footnote)
                        .padding(.horizontal, Theme.Metrics.contentPadding)
                        .padding(.vertical, Theme.Metrics.elementSpacing)
                        .themedControlSurface(
                            cornerRadius: Theme.Radius.capsule(height: 28)
                        )
                        .padding(.bottom, Theme.Metrics.contentPadding)
                }
                .allowsHitTesting(false)
            }
        }
        .compatAnimation(.easeOut(duration: 0.15), value: notice)
    }

    /// Показывает сообщение и убирает его само.
    ///
    /// Своим сообщением в окне, а не системным уведомлением: последнее просит
    /// разрешения, живёт в «Центре уведомлений» и приходит туда же, куда
    /// приходят чужие письма, — для подтверждения нажатия, которое человек
    /// только что сделал и видит, это несоразмерно.
    private func show(notice text: String) {
        noticeToken += 1
        let token = noticeToken
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard noticeToken == token else { return }
            notice = nil
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element.id) { position, day in
                    // Кеглем и цветом заголовка раздела, как в настройках, а не
                    // мелкой серой подписью. День — это то, по чему в списке
                    // ориентируются: он единственная точка опоры при прокрутке
                    // на три недели назад, и вторым планом ей стоять нельзя.
                    //
                    // Воздух сверху — только между группами. У первой его нет:
                    // расстояние от края плашки задаёт сама плашка, и оно
                    // должно совпадать с разделами настроек, а не складываться
                    // с ним в двойное.
                    Text(day.title)
                        .font(Font.subheadline.weight(.semibold))
                        .padding(.horizontal, Theme.Metrics.sectionSpacing)
                        .padding(.top, position == 0 ? 0 : Theme.Metrics.contentPadding)
                        .padding(.bottom, Theme.Metrics.tightSpacing)

                    // Разделительных линий между звонками нет.
                    //
                    // Они появились, когда строки было нечем отделить друг от
                    // друга, и решали задачу, которой больше нет: строка стала
                    // двухъярусной, значок исхода задал ей чёткое начало, а дни
                    // разделены заголовками. Линия поверх этого делит уже
                    // разделённое и превращает список в таблицу — а таблицу
                    // читают по колонкам, тогда как историю читают по строкам.
                    ForEach(day.records) { record in
                        CallHistoryRow(record: record)
                    }
                }

                // Догрузка вешается на появление последней строки, а не на
                // положение прокрутки: `LazyVStack` и `ScrollViewReader`
                // появились в macOS 11, а срез x86_64 обязан работать на
                // Catalina. Строка, доехавшая до глаз, — тот же сигнал, и он
                // работает везде одинаково.
                if model.historyHasMore {
                    HStack {
                        Spacer()
                        CompatSpinner()
                            .compatAccessibilityLabel("Загружаются более старые звонки")
                        Spacer()
                    }
                    .padding(Theme.Metrics.sectionSpacing)
                    .onAppear { model.loadMoreHistory() }
                }
            }
            // Поле у края плашки — `sectionSpacing`, ровно как внутри разделов
            // менеджерской страницы. Было `tightSpacing` плюс отступ первого
            // заголовка, и вместе они давали шестнадцать точек против восьми в
            // настройках: список начинался заметно ниже, чем всё остальное в
            // приложении.
            .padding(.vertical, Theme.Metrics.sectionSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Новый отбор — новый список, и он обязан начинаться сверху.
        //
        // Смена личности заставляет SwiftUI собрать `ScrollView` заново, а
        // собранный заново начинается с начала. Прокрутить его руками нечем:
        // `ScrollViewReader` появился в macOS 11, а срез x86_64 обязан работать
        // на Catalina. Без этого переключение профиля оставляло прокрутку от
        // прежнего списка — тот же промах, что уже случился с первым открытием
        // окна, только теперь в середине.
        //
        // В личность входит только отбор, но не число показанных строк: иначе
        // догрузка следующей страницы пересобирала бы список и швыряла бы
        // оператора обратно наверх ровно в тот момент, когда он долистал вниз.
        .id(scrollIdentity)
    }

    private var scrollIdentity: String {
        let profile = model.settings.profiles.activeID.uuidString
        let day = model.historySelectedDay.map { "\($0.timeIntervalSince1970)" } ?? "-"
        return "\(profile)/\(model.historyFilter.rawValue)/\(day)/\(model.historyOpenCount)"
    }

    // MARK: - Пусто

    /// Пустое состояние: чего нет и почему именно нет.
    ///
    /// Второе — не вежливость. «Пропущенных нет» на пустом окне неотличимо от
    /// сломанной истории, и оператор, включивший фильтр десять секунд назад,
    /// успевает об этом забыть. Поэтому когда записи есть, а под фильтр не
    /// попала ни одна, окно говорит об этом прямо и предлагает выход одним
    /// нажатием.
    private var emptyState: some View {
        VStack(spacing: Theme.Metrics.elementSpacing) {
            CompatSymbol(name: "clock", size: 24)
                .compatForeground(Theme.Palette.textTertiary)

            Text(emptyTitle)
                .font(.callout)

            if let explanation = emptyExplanation {
                Text(explanation)
                    .font(.footnote)
                    .compatForeground(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isFilteredOut {
                Button("Показать все") {
                    model.historyFilter = .all
                    model.historySelectedDay = nil
                }
                .font(.callout)
            }
        }
        .padding(Theme.Metrics.contentPadding)
        .frame(maxWidth: Theme.Metrics.historyMinWidth / 2)
    }

    /// Записи у профиля есть, но текущий отбор их не пропускает.
    private var isFilteredOut: Bool {
        (model.historyFilter != .all || model.historySelectedDay != nil)
            && model.historyTotalCountUnfiltered > 0
    }

    private var emptyTitle: String {
        guard model.settings.history.isEnabled else {
            return NSLocalizedString("История звонков выключена", comment: "пустой список истории")
        }
        guard isFilteredOut else {
            return NSLocalizedString("Звонков пока не было", comment: "пустой список истории")
        }
        if model.historySelectedDay != nil {
            return NSLocalizedString("В этот день звонков не было", comment: "пустой список истории")
        }
        switch model.historyFilter {
        case .all: return NSLocalizedString("Звонков пока не было", comment: "пустой список истории")
        case .incoming: return NSLocalizedString("Входящих в истории нет", comment: "пустой список истории")
        case .outgoing: return NSLocalizedString("Исходящих в истории нет", comment: "пустой список истории")
        case .missed: return NSLocalizedString("Пропущенных нет", comment: "пустой список истории")
        }
    }

    private var emptyExplanation: String? {
        guard model.settings.history.isEnabled else {
            // Куда идти, а не только что случилось: выключатель закрытый, и
            // менеджер до него не дойдёт сам.
            return NSLocalizedString("Включается в «Управлении». Пока она выключена, звонки нигде не записываются.", comment: "пустой список истории")
        }
        guard isFilteredOut else {
            return NSLocalizedString("Здесь появятся входящие и исходящие — вместе с тем, чем они кончились.", comment: "пустой список истории")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("Под этот отбор не попал ни один звонок из %lld.", comment: "пустой список истории после отбора"),
            model.historyTotalCountUnfiltered
        )
    }

    // Подвала у окна нет.
    //
    // Он говорил две вещи — «Записей: 24» и «Хранится 30 дн., дальше
    // удаляется», — и обе к этому моменту потеряли повод.
    //
    // Счёт был нужен, пока список обрывался на двухсотой записи: подпись
    // «Показаны 200 из 2847» была единственным признаком, что дальше что-то
    // есть. Теперь список догружается прокруткой, и «дальше» видно самим
    // списком.
    //
    // Срок хранения объяснял, почему звонка полугодовой давности не найти, —
    // ровно то, ради чего подпись и заводилась (M7d). Теперь то же самое
    // говорит календарь, и говорит сильнее: дни за сроком в нём просто не
    // нажимаются. Правило, которое нельзя нарушить, объясняет себя лучше
    // предложения о нём.
    //
    // Взамен полоса в 25 точек отдана списку — это ещё одна строка звонка на
    // каждом экране, а окно открывают ради строк.

    // MARK: - Дни

    /// Записи одного дня. День — ключ группы, он же её порядок: выборка
    /// приходит от новых к старым, и группировка этого порядка не меняет.
    private struct HistoryDay: Identifiable {
        let id: Date
        let title: String
        let records: [CallRecord]
    }

    private var days: [HistoryDay] {
        let calendar = Calendar.current
        var order: [Date] = []
        var grouped: [Date: [CallRecord]] = [:]

        for record in model.historyRecords {
            let day = calendar.startOfDay(for: record.startedAt)
            if grouped[day] == nil { order.append(day) }
            grouped[day, default: []].append(record)
        }

        return order.map { day in
            HistoryDay(id: day, title: HistoryDate.dayTitle(day), records: grouped[day] ?? [])
        }
    }
}

// MARK: - Даты

/// Форматы дат окна истории — одним местом на всё окно.
///
/// Заголовок группы и строка говорят об одном и том же дне, и разойтись эти два
/// ответа не имеют права: «Вчера» над строкой с сегодняшней датой — это ошибка,
/// которую заметят не сразу.
enum HistoryDate {

    /// «Сегодня» и «Вчера» словами, остальное датой.
    ///
    /// Два дня, а не больше: «позавчера» человек уже переводит в дату сам, а
    /// «в среду» на третьей неделе истории означает четыре разных среды.
    static func dayTitle(_ day: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        if day == today { return NSLocalizedString("Сегодня", comment: "заголовок дня в истории") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return NSLocalizedString("Вчера", comment: "заголовок дня в истории")
        }
        return dayFormatter.string(from: day)
    }

    /// Время и дата в строке: `15:57 06.08.2026`.
    ///
    /// Полная дата в каждой строке — при том, что день написан и в заголовке
    /// группы. Повтор принят сознательно: строку показывают коллеге и
    /// пересказывают в поддержку, и она обязана быть полной сама по себе.
    static func stamp(_ date: Date) -> String {
        stampFormatter.string(from: date)
    }

    /// Подпись на кнопке календаря — та же дата, что в строках.
    static func shortDay(_ date: Date) -> String {
        shortDayFormatter.string(from: date)
    }

    static func monthTitle(_ date: Date) -> String {
        monthFormatter.string(from: date)
    }

    private static let dayFormatter = make("d MMMM")
    private static let stampFormatter = make("HH:mm dd.MM.yyyy")
    private static let shortDayFormatter = make("dd.MM.yyyy")
    private static let monthFormatter = make("LLLL yyyy")

    private static func make(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        // Язык приложения, а не зашитый русский.
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = format
        return formatter
    }
}

// MARK: - Значок исхода

/// Четыре состояния звонка одним значком.
///
/// **Форма несёт то же, что цвет.** Залитый кружок — разговор состоялся, кольцо
/// — не состоялся; стрелка внутрь — входящий, наружу — исходящий. Поэтому при
/// дальтонизме и на чёрно-белом снимке значок читается целиком, а цвет остаётся
/// ускорителем, а не единственным носителем смысла.
///
/// Стрелка рисуется формой, а не берётся из комплекта иконок, — тем же приёмом,
/// что `ChevronDown`: три отрезка проще задать, чем нарисовать, и они остаются
/// резкими на любом размере. Комплект для Catalina от этого не растёт.
struct CallOutcomeBadge: View {

    let isIncoming: Bool
    let isCompleted: Bool
    let color: Color
    var size: CGFloat = Theme.Metrics.outcomeBadgeSize
    var label: LocalizedStringKey?

    init(record: CallRecord) {
        isIncoming = record.direction == .incoming
        isCompleted = record.isAnswered
        color = Self.color(for: record)
        label = Self.label(for: record)
    }

    /// Тот же значок вне списка — на кнопках фильтров.
    ///
    /// Отдельный инициализатор, а не поддельная `CallRecord`: подсказка на
    /// кнопке не про конкретный звонок, и собирать под неё запись значило бы
    /// заводить звонок, которого не было.
    init(isIncoming: Bool, isCompleted: Bool, color: Color, size: CGFloat, label: LocalizedStringKey? = nil) {
        self.isIncoming = isIncoming
        self.isCompleted = isCompleted
        self.color = color
        self.size = size
        self.label = label
    }

    var body: some View {
        ZStack {
            if isCompleted {
                Circle().fill(color)
            } else {
                Circle().strokeBorder(color, lineWidth: size / 14)
            }

            CallDirectionArrow(isIncoming: isIncoming)
                .stroke(
                    style: StrokeStyle(
                        lineWidth: size / 14, lineCap: .round, lineJoin: .round
                    )
                )
                // Внутри залитого кружка стрелка рисуется фоном окна, а не
                // белым: в тёмной теме белая стрелка на светло-сером кружке
                // «дозвонился» почти пропадает, а фон окна по определению
                // контрастен своей теме.
                .compatForeground(isCompleted ? Color(NSColor.windowBackgroundColor) : color)
                .frame(width: size / 2, height: size / 2)
        }
        .frame(width: size, height: size)
        .compatAccessibilityLabel(label ?? "")
    }

    private static func color(for record: CallRecord) -> Color {
        switch record.outcome {
        case .completed:
            return record.direction == .incoming
                ? Theme.Palette.outcomeAnswered
                : Theme.Palette.outcomeCompleted
        case .missed:
            return Theme.Palette.outcomeMissed
        case .busy, .noAnswer, .unknownNumber, .declined, .failed:
            return Theme.Palette.outcomeUnreachable
        }
    }

    /// Для VoiceOver значок обязан говорить то же, что видно глазом: цвет и
    /// форму он не читает, а состояний четыре.
    private static func label(for record: CallRecord) -> LocalizedStringKey {
        switch (record.direction, record.isAnswered) {
        case (.incoming, true): return "Принял"
        case (.incoming, false): return "Пропустил"
        case (.outgoing, true): return "Дозвонился"
        case (.outgoing, false): return "Не дозвонился"
        }
    }
}

/// Подсказка на кнопке фильтра — стрелка того же вида, что в строках.
///
/// Смысл в том, что стрелка **та же**: кнопка учит читать список, а не заводит
/// второй язык. Направление у неё то же, цвет у «Пропущенных» тот же красный.
///
/// **Кольца вокруг стрелки здесь нет, хотя в строке у пропущенного оно есть.**
/// Живое окно показало, почему: на четырнадцати точках красное кольцо с
/// диагональной чертой внутри читается как знак «запрещено», а не как
/// пропущенный звонок — головку стрелки на такой доле размера уже не видно.
/// Кольцо несёт «разговор не состоялся», и в списке это различие обязательно;
/// на кнопке оно не нужно вовсе — рядом стоит слово «Пропущенные».
///
/// По той же причине здесь остаётся различие одним цветом, хотя в списке так
/// нельзя: там значок единственный носитель смысла, а тут он подпись к подписи.
///
/// У «Всех» значка нет: подсказывать нечего, а четвёртая фигура ради симметрии
/// сообщала бы, что и «Все» чем-то отбирают.
private struct FilterGlyph: View {

    let filter: CallHistoryStore.Filter

    var body: some View {
        if let direction {
            CallDirectionArrow(isIncoming: direction)
                .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .compatForeground(
                    filter == .missed ? Theme.Palette.outcomeMissed : Theme.Palette.textSecondary
                )
                .frame(
                    width: Theme.Metrics.historyFilterGlyph,
                    height: Theme.Metrics.historyFilterGlyph
                )
        }
    }

    /// nil — у фильтра нет направления, значит нет и стрелки.
    private var direction: Bool? {
        switch filter {
        case .all: return nil
        case .incoming, .missed: return true
        case .outgoing: return false
        }
    }
}

/// Снимок открытой части списка — в буфер обмена.
///
/// **Зачем.** Оператор пересказывает историю в переписке: «вот эти три звонка».
/// Системный снимок экрана это умеет, но требует прицелиться мышью по краям
/// списка, а промахнувшись — захватывает соседнюю CRM с чужими данными. Кнопка
/// берёт ровно ту область, которую видно, и ничего сверх неё.
///
/// **Снимается плашка списка, а не окно целиком.** В кадр не попадают ни
/// заголовок с номером профиля, ни кнопки фильтров. Это осознанное сужение:
/// просили снимок «открытой части истории», и всё, что не строки, — контекст,
/// который человек и так допишет словами.
/// `@MainActor` целиком: класс живёт только внутри AppKit — держит `NSView` и
/// рисует в графический контекст, а и то и другое существует только на главном
/// потоке.
@MainActor
final class HistorySnapshotAnchor {

    /// Слабо: держать вьюху здесь означало бы пережить окно, которое её
    /// закрыло.
    weak var view: NSView?

    /// Собирает снимок области, которую занимает якорь.
    ///
    /// **Через `cacheDisplay` окна, а не через снимок экрана.**
    /// `CGWindowListCreateImage` дал бы то же изображение вместе со стеклом, но
    /// с macOS 10.15 требует разрешения на запись экрана — системный запрос,
    /// который на рабочем месте колл-центра выглядит как «программа смотрит,
    /// что я делаю». Ради кнопки, копирующей собственный список, такую цену
    /// платить нельзя.
    ///
    /// Цена своего пути: стекло `.behindWindow` рисует не приложение, а
    /// оконный сервер, и в `cacheDisplay` оно не попадает вовсе. Поэтому под
    /// снимок подкладывается непрозрачный фон окна — и это к лучшему:
    /// полупрозрачный PNG в переписке показал бы чужой рабочий стол сквозь
    /// собственные строки.
    ///
    /// **Снимок подписывается, а не отдаётся голым.** Он уходит в переписку, то
    /// есть человеку, у которого нет ни окна, ни его заголовка: он видит столбец
    /// времён и не может их прочитать. Поэтому над рамкой стоят две вещи — чей
    /// это список и который час на той машине, вместе с поясом. Без пояса
    /// «21:07» в строке означает разное в Москве и в Новосибирске, а разбирают
    /// по таким снимкам как раз опоздания и пропущенные.
    func image(profile: String) -> NSImage? {
        guard let view,
              let content = view.window?.contentView,
              let layer = content.layer
        else { return nil }

        let area = view.convert(view.bounds, to: content)
        let whole = content.bounds
        guard area.width > 1, area.height > 1, whole.width > 1, whole.height > 1 else { return nil }

        let scale = view.window?.backingScaleFactor ?? 2

        // **Слой, а не `cacheDisplay`.** Первый заход снимал через
        // `cacheDisplay(in:to:)`, и живая проверка показала, чем это кончается:
        // в снимок попали только фигуры, нарисованные путями, — значки исхода,
        // — а весь текст пропал. SwiftUI держит надписи в содержимом слоёв, и
        // через путь рисования AppKit они не проходят вовсе. Отрисовка слоя
        // забирает и то и другое.
        guard let rendered = Self.render(
            layer: layer, size: whole.size, scale: scale, isFlipped: content.isFlipped
        ) else { return nil }

        // Обрезка в пикселях. У `CGImage` начало координат сверху слева, а у
        // вьюхи — снизу слева, если она не перевёрнута; `NSHostingView`
        // перевёрнута, но полагаться на это нельзя, поэтому считаются оба
        // случая.
        let topInset = content.isFlipped ? area.minY : whole.height - area.maxY
        let crop = CGRect(
            x: (area.minX * scale).rounded(),
            y: (topInset * scale).rounded(),
            width: (area.width * scale).rounded(),
            height: (area.height * scale).rounded()
        )
        guard let cropped = rendered.cropping(to: crop) else { return nil }

        return Self.compose(
            cropped,
            size: area.size,
            profile: profile,
            appearanceOf: view
        )
    }

    /// Подпись справа: который час на этой машине и в каком поясе.
    ///
    /// Пояс — числом от UTC, а не сокращением. «MSK» знают не все, а на
    /// половине машин `abbreviation()` и так возвращает «GMT+3»; смещение
    /// читается однозначно и переводится в чужой пояс вычитанием.
    static func systemTime(now: Date = Date()) -> String {
        let offset = TimeZone.current.secondsFromGMT(for: now)
        let sign = offset < 0 ? "-" : "+"
        let hours = abs(offset) / 3600
        let minutes = (abs(offset) % 3600) / 60
        let zone = minutes == 0
            ? "UTC\(sign)\(hours)"
            : String(format: "UTC%@%d:%02d", sign, hours, minutes)
        return "\(HistoryDate.stamp(now)) · \(zone)"
    }

    /// Рисует слой целиком в свой контекст.
    /// Рисует слой целиком в свой контекст.
    ///
    /// **Переворот обязателен для перевёрнутой вьюхи.** У `CGContext` начало
    /// координат внизу слева, у `NSHostingView` — вверху слева, и `render(in:)`
    /// эту разницу не сглаживает: без переворота снимок выходит вверх ногами.
    /// Живая проверка показала это вдвойне — перевёрнутое изображение потом
    /// резалось по координатам, отсчитанным сверху, и в кадр попадала зеркальная
    /// область, то есть ряд кнопок вместо конца списка.
    private static func render(
        layer: CALayer,
        size: CGSize,
        scale: CGFloat,
        isFlipped: Bool
    ) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: Int((size.width * scale).rounded()),
                height: Int((size.height * scale).rounded()),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.scaleBy(x: scale, y: scale)
        if isFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        return context.makeImage()
    }

    /// Собирает готовый снимок: поля, шапка, рамка и сам список внутри неё.
    ///
    /// Непрозрачный фон здесь не украшение. Стекло `.behindWindow` рисует не
    /// приложение, а оконный сервер, и в отрисовку слоя оно не попадает; без
    /// подложки снимок вышел бы полупрозрачным — то есть в переписке показал бы
    /// чужой рабочий стол сквозь собственные строки.
    private static func compose(
        _ image: CGImage,
        size: CGSize,
        profile: String,
        appearanceOf view: NSView
    ) -> NSImage? {
        let pad = Theme.Metrics.contentPadding
        let gap = Theme.Metrics.elementSpacing
        let captionHeight: CGFloat = 16

        let total = CGSize(
            width: size.width + pad * 2,
            height: size.height + captionHeight + gap + pad * 2
        )
        let scale = CGFloat(image.width) / size.width

        guard let canvas = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((total.width * scale).rounded()),
            pixelsHigh: Int((total.height * scale).rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        canvas.size = total

        guard let context = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }

        // Начало координат внизу слева: список стоит на нижнем поле, шапка над
        // ним.
        let listRect = CGRect(x: pad, y: pad, width: size.width, height: size.height)
        let captionRect = CGRect(
            x: pad,
            y: listRect.maxY + gap,
            width: size.width,
            height: captionHeight
        )

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        // Всё рисование — под оформлением окна, а не под текущим: тёмное окно
        // на светлой системе иначе получило бы светлую подложку под светлым же
        // текстом.
        withAppearance(of: view) {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath.fill(CGRect(origin: .zero, size: total))

            context.cgContext.draw(image, in: listRect)

            // Рамка по краю списка, радиусом плашки: снимок кладут в переписку
            // на чужой фон, и без рамки строки на тёмной подложке сливаются с
            // тёмным фоном мессенджера — список перестаёт читаться как
            // отдельная вещь.
            let border = NSBezierPath(
                roundedRect: listRect.insetBy(dx: -0.5, dy: -0.5),
                xRadius: Theme.Radius.surface,
                yRadius: Theme.Radius.surface
            )
            border.lineWidth = 1
            // Третий уровень текста, а не `separatorColor`: тот рассчитан на
            // линию внутри окна и в светлой теме на светлом поле почти
            // пропадает, а рамке положено быть видной в обеих.
            NSColor.tertiaryLabelColor.setStroke()
            border.stroke()

            draw(profile, in: captionRect, alignment: .left)
            draw(systemTime(), in: captionRect, alignment: .right)
        }
        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: total)
        result.addRepresentation(canvas)
        return result
    }

    /// Надпись шапки. Мелкая и вторым планом: она объясняет снимок, а не
    /// соперничает с ним.
    private static func draw(
        _ text: String,
        in rect: CGRect,
        alignment: NSTextAlignment
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail

        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private static func withAppearance(of view: NSView, _ body: () -> Void) {
        if #available(macOS 11.0, *) {
            view.effectiveAppearance.performAsCurrentDrawingAppearance(body)
        } else {
            let saved = NSAppearance.current
            NSAppearance.current = view.effectiveAppearance
            body()
            NSAppearance.current = saved
        }
    }
}

/// Пустая вьюха, которая сообщает якорю свои границы.
private struct HistorySnapshotArea: NSViewRepresentable {

    let anchor: HistorySnapshotAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

/// Кнопка снимка.
private struct HistorySnapshotButton: View {

    let anchor: HistorySnapshotAnchor
    /// Чей это список — тем же словом, что в заголовке окна.
    let profile: String
    let isEnabled: Bool
    let onResult: (String) -> Void

    var body: some View {
        Button {
            copy()
        } label: {
            CameraGlyph()
                .stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                .frame(width: Theme.Icon.medium, height: Theme.Icon.medium)
                .padding(.horizontal, Theme.Metrics.tightSpacing)
                .padding(.vertical, Theme.Metrics.hairSpacing)
        }
        .disabled(!isEnabled)
        .compatHelp("Скопировать снимок списка в буфер обмена")
        .compatAccessibilityLabel("Снимок списка")
    }

    private func copy() {
        guard let image = anchor.image(profile: profile) else {
            onResult(NSLocalizedString("Снимок не получился", comment: "снимок списка истории"))
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        onResult(NSLocalizedString("Снимок скопирован — вставьте в переписку", comment: "снимок списка истории"))
    }
}

/// Фотоаппарат: корпус, видоискатель и объектив.
struct CameraGlyph: Shape {

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        var path = Path()

        path.addRoundedRect(
            in: CGRect(x: 0, y: side * 0.24, width: side, height: side * 0.64),
            cornerSize: CGSize(width: side * 0.14, height: side * 0.14)
        )

        // Видоискатель: трапеция на крышке. Без неё корпус с кружком читается
        // как что угодно круглое в рамке.
        path.move(to: CGPoint(x: side * 0.28, y: side * 0.24))
        path.addLine(to: CGPoint(x: side * 0.37, y: side * 0.09))
        path.addLine(to: CGPoint(x: side * 0.63, y: side * 0.09))
        path.addLine(to: CGPoint(x: side * 0.72, y: side * 0.24))

        path.addEllipse(
            in: CGRect(x: side * 0.34, y: side * 0.4, width: side * 0.32, height: side * 0.32)
        )
        return path
    }
}

/// Календарь: рамка, отрывной верх и два крепления.
///
/// Формой, а не значком из комплекта, — тем же приёмом, что стрелка исхода и
/// `ChevronDown`. Часы на этой кнопке стояли ровно одну итерацию и были
/// неверны: часы отвечают на «во сколько», а кнопка выбирает день. В комплекте
/// для Catalina календаря нет, и рисовать растр ради пяти отрезков незачем.
struct CalendarGlyph: Shape {

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        var path = Path()

        // Рамка месяца. Верхняя четверть — «шапка», отделённая линией.
        let body = CGRect(x: 0, y: side * 0.12, width: side, height: side * 0.88)
        path.addRoundedRect(in: body, cornerSize: CGSize(width: side * 0.14, height: side * 0.14))

        let headline = body.minY + side * 0.28
        path.move(to: CGPoint(x: body.minX, y: headline))
        path.addLine(to: CGPoint(x: body.maxX, y: headline))

        // Два крепления сверху: без них рамка читается как обычный
        // прямоугольник, а с ними — как календарь, даже на 12 точках.
        for x in [side * 0.3, side * 0.7] {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: side * 0.24))
        }
        return path
    }
}

/// Диагональная стрелка: линия и две черты наконечника.
private struct CallDirectionArrow: Shape {

    let isIncoming: Bool

    func path(in rect: CGRect) -> Path {
        let size = min(rect.width, rect.height)
        // Начало и конец: входящая приходит сверху справа вниз налево,
        // исходящая уходит снизу слева вверх направо.
        let tail = isIncoming
            ? CGPoint(x: size, y: 0)
            : CGPoint(x: 0, y: size)
        let head = isIncoming
            ? CGPoint(x: 0, y: size)
            : CGPoint(x: size, y: 0)

        var path = Path()
        path.move(to: tail)
        path.addLine(to: head)

        // Наконечник — две черты в половину длины, обе от острия.
        let wing = size * 0.55
        if isIncoming {
            path.move(to: head)
            path.addLine(to: CGPoint(x: head.x + wing, y: head.y))
            path.move(to: head)
            path.addLine(to: CGPoint(x: head.x, y: head.y - wing))
        } else {
            path.move(to: head)
            path.addLine(to: CGPoint(x: head.x - wing, y: head.y))
            path.move(to: head)
            path.addLine(to: CGPoint(x: head.x, y: head.y + wing))
        }
        return path
    }
}

// MARK: - Строка

/// Строка истории.
///
/// Две линии. Сверху — с кем говорили и чем это кончилось, снизу — чем это
/// подтверждается и когда было. Повтор набора справа отдельной кнопкой, а не
/// нажатием по строке: нажатие по строке в списке означает «выбрать», и звонок
/// от него — это звонок, которого не хотели.
private struct CallHistoryRow: View {

    @EnvironmentObject private var model: AppModel

    let record: CallRecord

    private var canRedial: Bool { model.canPlaceCall && !record.number.isEmpty }

    var body: some View {
        HStack(spacing: Theme.Metrics.sectionSpacing) {
            CallOutcomeBadge(record: record)

            VStack(alignment: .leading, spacing: Theme.Metrics.hairSpacing) {
                // Имя, а нет имени — номер. До M9 имён почти нет: `display_name`
                // заполняется только тем, что пришло в `From`, а боевой FreePBX
                // кладёт туда тот же номер. Пустое главное место было бы хуже
                // повторения — строка выглядела бы сломанной.
                Text(record.title)
                    .compatMonospacedDigit()
                    .lineLimit(1)

                Text(subtitle)
                    .font(.footnote)
                    .compatForeground(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Metrics.elementSpacing)

            // Колонка постоянной ширины: иначе кнопки повторного набора ездят
            // от длины исхода и не стоят на одной вертикали.
            VStack(alignment: .trailing, spacing: Theme.Metrics.hairSpacing) {
                Text(outcome)
                    .compatMonospacedDigit()
                    .compatForeground(
                        record.isMissed ? Theme.Palette.outcomeMissed : Theme.Palette.textPrimary
                    )
                    .lineLimit(1)

                Text(HistoryDate.stamp(record.startedAt))
                    .font(.footnote)
                    .compatMonospacedDigit()
                    .compatForeground(Theme.Palette.textSecondary)
            }
            .frame(width: Theme.Metrics.historyOutcomeColumn, alignment: .trailing)

            Button {
                model.redial(record)
            } label: {
                // Не зелёная, хотя кнопка и звонит: цвет в этом окне
                // принадлежит значку исхода, и зелёная трубка в каждой строке
                // спорила бы с ним за внимание.
                CompatSymbol(name: "phone.fill")
                    .compatForeground(
                        canRedial ? Theme.Palette.textPrimary : Theme.Palette.textTertiary
                    )
                    // Квадрат, а не набивка по сторонам. Разная набивка по
                    // горизонтали и вертикали давала приплюснутый
                    // прямоугольник — форму, которой в приложении больше нигде
                    // нет: клавиши макросов, кнопки управления и цифровые цели
                    // либо квадратные, либо явно широкие.
                    .frame(
                        width: Theme.Metrics.historyRedialButton,
                        height: Theme.Metrics.historyRedialButton
                    )
                    // Рамка с фоном, а не голый значок: без неё оператор не
                    // понимает, что это кнопка, а не пометка строки.
                    .themedControlSurface(cornerRadius: Theme.Radius.control)
                    .hoverHighlight(isEnabled: canRedial)
            }
            .buttonStyle(.plain)
            .disabled(!canRedial)
            .compatHelp(canRedial ? "Позвонить на \(record.number)" : "Сейчас позвонить нельзя")
            .compatAccessibilityLabel("Позвонить ещё раз")
        }
        // Кегль задаётся строке целиком, а не каждой надписи: `.callout` на
        // содержимое, `.footnote` на второй план — те же два голоса, что на
        // странице настроек.
        .font(.callout)
        .padding(.vertical, Theme.Metrics.elementSpacing)
        // Тот же отступ внутри плашки, что у разделов настроек
        // (`sectionSpacing`): плашка стоит на `contentPadding` от края окна, и
        // содержимое начинается на 20 точках — как на менеджерской странице.
        // Прежние 6 давали 18 и расходились с ней ровно на две точки, то есть
        // на глаз не читались, а числами не совпадали.
        .padding(.horizontal, Theme.Metrics.sectionSpacing)
    }

    /// Под именем — то, чем оно подтверждается: сам номер, если наверху стоит
    /// не он, и пометки перевода и конференции.
    ///
    /// **Причины отказа здесь нет.** Она хранится в записи и попадает в журнал,
    /// но в окно не выходит: полностью она не помещается, а обрезанная («отказ
    /// 503 service…») не отвечает ни на один вопрос. Вместо неё справа стоит
    /// слово исхода, и шести слов оператору хватает, чтобы решить, что делать
    /// дальше.
    private var subtitle: String {
        var parts: [String] = []
        // Номер стоит внизу всегда, даже когда он же написан наверху.
        //
        // Повтор выбран сознательно: до M9 имён почти нет, и без него нижняя
        // строка у большинства звонков пустая — строка выглядит наполовину
        // отвалившейся, а высоту всё равно занимает, потому что справа под ней
        // стоит дата. Пустое место, которое нельзя убрать, хуже повтора.
        if !record.number.isEmpty {
            parts.append(record.number)
        }
        if record.role == .consultation {
            parts.append(NSLocalizedString("консультация", comment: "пометка звонка в истории"))
        }
        if record.wasTransferred {
            parts.append(NSLocalizedString("перевод", comment: "пометка звонка в истории"))
        }
        if record.wasConference {
            parts.append(NSLocalizedString("конференция", comment: "пометка звонка в истории"))
        }
        return parts.joined(separator: " · ")
    }

    /// Длительность, если разговор был; иначе слово исхода.
    private var outcome: String {
        if let duration = record.duration {
            return Self.duration(duration)
        }
        if record.endedAt == nil {
            return NSLocalizedString("идёт", comment: "звонок ещё не кончился")
        }
        return record.outcome.title ?? ""
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Календарь

/// Кнопка выбора дня и всплывающий календарь за ней.
///
/// Свой календарь, а не `DatePicker`: точки под днями, в которые были звонки,
/// системный не рисует, а именно они отвечают на «в какой день это было» —
/// без них человек тыкает в пустые дни и решает, что история сломана. Заодно
/// снимается вопрос о том, как графический стиль `DatePicker` выглядит на
/// Catalina: своя сетка везде одинакова.
private struct HistoryDayButton: View {

    @EnvironmentObject private var model: AppModel

    @State private var isCalendarShown = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                isCalendarShown = true
            } label: {
                HStack(spacing: Theme.Metrics.tightSpacing) {
                    CalendarGlyph()
                        .stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                        .frame(width: Theme.Icon.medium, height: Theme.Icon.medium)
                    if let day = model.historySelectedDay {
                        Text(HistoryDate.shortDay(day))
                            .compatMonospacedDigit()
                            // Дата не ужимается: «04.08.20…» — это дата, по
                            // которой нельзя сказать, какой год выбран, а
                            // ужимал её ряд, который и так стоит по центру и
                            // места не считает.
                            .fixedSize()
                    }
                }
                .padding(.horizontal, Theme.Metrics.tightSpacing)
                .padding(.vertical, Theme.Metrics.hairSpacing)
            }
            .compatProminentButtonStyle(model.historySelectedDay != nil)
            .compatHelp("Показать звонки за один день")

            // Крестик снимает отбор, не открывая того, что его поставило.
            if model.historySelectedDay != nil {
                Button {
                    model.historySelectedDay = nil
                } label: {
                    CompatSymbol(name: "xmark.circle.fill", size: Theme.Icon.medium)
                        .compatForeground(Theme.Palette.textSecondary)
                        .padding(.leading, Theme.Metrics.tightSpacing)
                }
                .buttonStyle(.plain)
                .compatHelp("Показать все дни")
                .compatAccessibilityLabel("Снять отбор по дню")
            }
        }
        .popover(isPresented: $isCalendarShown, arrowEdge: .bottom) {
            HistoryCalendar(isPresented: $isCalendarShown)
                .environmentObject(model)
        }
    }
}

/// Месяц сеткой семь на шесть.
///
/// Границы — не «тридцать дней», а срок хранения: тридцать всего лишь
/// умолчание, и администратор ставит своё. Календарь, предлагающий день, записи
/// за который уже удалены, обещает то, чего нет.
private struct HistoryCalendar: View {

    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool

    /// Какой месяц показан. Начинается с месяца выбранного дня, а нет
    /// выбранного — с текущего.
    @State private var month: Date = Date()

    /// Стрелки месяца. Числом, а не `.title3`: тот появился в macOS 11, а
    /// срез x86_64 обязан работать на Catalina. Это ровно тот класс промахов,
    /// который Debug не ловит — он собирает только arm64 с планкой 11.0.
    private static let monthArrow = Font.system(size: 16, weight: .medium)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // Язык приложения, а не зашитый русский: от него зависит и первый
        // день недели, а он у русской и английской раскладок разный.
        calendar.locale = .autoupdatingCurrent
        // Неделя с понедельника: воскресенье первым — это чужая привычка, и
        // рабочая неделя в такой сетке разрывается пополам.
        calendar.firstWeekday = 2
        return calendar
    }

    var body: some View {
        VStack(spacing: Theme.Metrics.elementSpacing) {
            header
            weekdays
            grid
        }
        .padding(Theme.Metrics.contentPadding)
        // Каждое открытие возвращает календарь к выбранному дню: пролистав до
        // прошлого месяца и закрыв окно, оператор ожидает открыть его там же,
        // где стоит отбор, а не там, где случайно остановился.
        .onAppear { month = model.historySelectedDay ?? Date() }
    }

    private var header: some View {
        HStack {
            Button {
                shiftMonth(-1)
            } label: {
                Text("‹").font(Self.monthArrow)
            }
            .buttonStyle(.plain)
            .disabled(!canShow(month: shifted(by: -1)))
            .compatAccessibilityLabel("Предыдущий месяц")

            Spacer()
            Text(HistoryDate.monthTitle(month))
                .font(Font.subheadline.weight(.semibold))
            Spacer()

            Button {
                shiftMonth(1)
            } label: {
                Text("›").font(Self.monthArrow)
            }
            .buttonStyle(.plain)
            .disabled(!canShow(month: shifted(by: 1)))
            .compatAccessibilityLabel("Следующий месяц")
        }
    }

    /// Сокращения дней в том порядке, в каком их показывает система.
    private static var weekdayTitles: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private var weekdays: some View {
        HStack(spacing: 0) {
            // Дни берутся у календаря, а не переводом: от языка зависят и
            // сами сокращения, и то, с какого дня начинается неделя, — список
            // из семи строк знал бы только первое.
            ForEach(Self.weekdayTitles, id: \.self) { title in
                Text(title)
                    .font(.footnote)
                    .compatForeground(Theme.Palette.textSecondary)
                    .frame(width: Theme.Metrics.historyDayCell)
            }
        }
    }

    private var grid: some View {
        // `VStack` из `HStack`, а не `Grid`: тот появился в macOS 13, а срез
        // x86_64 обязан работать на Catalina.
        VStack(spacing: Theme.Metrics.hairSpacing) {
            ForEach(weeks, id: \.first) { week in
                HStack(spacing: 0) {
                    ForEach(week, id: \.self) { day in
                        cell(day)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ day: Date) -> some View {
        let isInMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let isSelected = model.historySelectedDay == day
        let isAvailable = isInMonth && isWithinRetention(day)

        Button {
            model.historySelectedDay = day
            isPresented = false
        } label: {
            VStack(spacing: 1) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.callout)
                    .compatMonospacedDigit()
                // Точка отвечает на «работал ли я в этот день», а не «были ли
                // в этот день пропущенные»: считается без фильтра, иначе
                // календарь пустел бы при его переключении.
                Circle()
                    .fill(model.historyDaysWithCalls.contains(day)
                          ? Theme.Palette.textSecondary
                          : Color.clear)
                    .frame(width: Theme.Metrics.historyDayDot, height: Theme.Metrics.historyDayDot)
            }
            .frame(width: Theme.Metrics.historyDayCell, height: Theme.Metrics.historyDayCell)
            .compatBackground {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
            }
            .hoverHighlight(isEnabled: isAvailable)
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        // Дни соседних месяцев и дни за сроком хранения показываются
        // погашенными, а не прячутся: пустая клетка ломает сетку недели, и
        // считать по ней даты становится нельзя.
        .opacity(isAvailable ? 1 : Theme.Metrics.disabledOpacity * 0.6)
    }

    // MARK: - Счёт дней

    /// Шесть недель по семь дней, начиная с понедельника недели, в которую
    /// попадает первое число. Шесть, а не пять: месяц из 31 дня, начавшийся в
    /// воскресенье, занимает именно шесть строк, и сетка не должна прыгать в
    /// высоте от месяца к месяцу.
    private var weeks: [[Date]] {
        guard
            let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
            let start = calendar.dateInterval(of: .weekOfYear, for: first)?.start
        else { return [] }

        return (0..<6).map { week in
            (0..<7).compactMap { day in
                calendar.date(byAdding: .day, value: week * 7 + day, to: start)
                    .map { calendar.startOfDay(for: $0) }
            }
        }
    }

    private var horizon: Date {
        let days = min(max(model.settings.history.maximumAgeInDays, 1), 3650)
        return calendar.startOfDay(
            for: Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        )
    }

    private func isWithinRetention(_ day: Date) -> Bool {
        day >= horizon && day <= calendar.startOfDay(for: Date())
    }

    private func shifted(by months: Int) -> Date {
        calendar.date(byAdding: .month, value: months, to: month) ?? month
    }

    private func shiftMonth(_ months: Int) {
        month = shifted(by: months)
    }

    /// Месяц показывается, если в него попадает хоть один день срока хранения.
    private func canShow(month candidate: Date) -> Bool {
        guard let interval = calendar.dateInterval(of: .month, for: candidate) else { return false }
        return interval.end > horizon && interval.start <= Date()
    }
}
