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
        return profile.isEmpty ? "История звонков" : "История звонков — \(profile)"
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
                    Text(item.title)
                        .padding(.horizontal, Theme.Metrics.tightSpacing)
                        .padding(.vertical, Theme.Metrics.hairSpacing)
                }
                .compatProminentButtonStyle(model.historyFilter == item)
            }
            HistoryDayButton()
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
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(days) { day in
                    // Кеглем и цветом заголовка раздела, как в настройках, а не
                    // мелкой серой подписью. День — это то, по чему в списке
                    // ориентируются: он единственная точка опоры при прокрутке
                    // на три недели назад, и вторым планом ей стоять нельзя.
                    Text(day.title)
                        .font(Font.subheadline.weight(.semibold))
                        .padding(.horizontal, Theme.Metrics.sectionSpacing)
                        .padding(.top, Theme.Metrics.contentPadding)
                        .padding(.bottom, Theme.Metrics.tightSpacing)

                    ForEach(day.records) { record in
                        if record.id != day.records.first?.id {
                            // Разделитель между звонками, а не под каждым:
                            // линия под последней строкой группы отрезала бы
                            // её от заголовка следующего дня, который и так
                            // разделяет сильнее любой линии.
                            Divider()
                                .padding(.leading, Theme.Metrics.sectionSpacing)
                        }
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
            .padding(.vertical, Theme.Metrics.tightSpacing)
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
            return "История звонков выключена"
        }
        guard isFilteredOut else { return "Звонков пока не было" }
        if model.historySelectedDay != nil { return "В этот день звонков не было" }
        switch model.historyFilter {
        case .all: return "Звонков пока не было"
        case .incoming: return "Входящих в истории нет"
        case .outgoing: return "Исходящих в истории нет"
        case .missed: return "Пропущенных нет"
        }
    }

    private var emptyExplanation: String? {
        guard model.settings.history.isEnabled else {
            // Куда идти, а не только что случилось: выключатель закрытый, и
            // менеджер до него не дойдёт сам.
            return "Включается в «Управлении». Пока она выключена, звонки нигде не записываются."
        }
        guard isFilteredOut else {
            return "Здесь появятся входящие и исходящие — вместе с тем, чем они кончились."
        }
        return "Под этот отбор не попал ни один звонок из \(model.historyTotalCountUnfiltered)."
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
        if day == today { return "Сегодня" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return "Вчера"
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
        formatter.locale = Locale(identifier: "ru_RU")
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

    let record: CallRecord

    var body: some View {
        ZStack {
            if isCompleted {
                Circle().fill(color)
            } else {
                Circle().strokeBorder(color, lineWidth: 1.5)
            }

            CallDirectionArrow(isIncoming: record.direction == .incoming)
                .stroke(
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                )
                // Внутри залитого кружка стрелка рисуется фоном окна, а не
                // белым: в тёмной теме белая стрелка на светло-сером кружке
                // «дозвонился» почти пропадает, а фон окна по определению
                // контрастен своей теме.
                .compatForeground(isCompleted ? Color(NSColor.windowBackgroundColor) : color)
                .frame(
                    width: Theme.Metrics.historyBadgeSize / 2,
                    height: Theme.Metrics.historyBadgeSize / 2
                )
        }
        .frame(width: Theme.Metrics.historyBadgeSize, height: Theme.Metrics.historyBadgeSize)
        .compatAccessibilityLabel(label)
    }

    private var isCompleted: Bool { record.isAnswered }

    private var color: Color {
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
    private var label: String {
        switch (record.direction, record.isAnswered) {
        case (.incoming, true): return "Принял"
        case (.incoming, false): return "Пропустил"
        case (.outgoing, true): return "Дозвонился"
        case (.outgoing, false): return "Не дозвонился"
        }
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
            parts.append("консультация")
        }
        if record.wasTransferred {
            parts.append("перевод")
        }
        if record.wasConference {
            parts.append("конференция")
        }
        return parts.joined(separator: " · ")
    }

    /// Длительность, если разговор был; иначе слово исхода.
    private var outcome: String {
        if let duration = record.duration {
            return Self.duration(duration)
        }
        if record.endedAt == nil {
            return "идёт"
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
        calendar.locale = Locale(identifier: "ru_RU")
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

    private var weekdays: some View {
        HStack(spacing: 0) {
            ForEach(["пн", "вт", "ср", "чт", "пт", "сб", "вс"], id: \.self) { title in
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
