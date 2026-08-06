import CallHistory
import SwiftUI

/// Окно «История звонков».
///
/// Отдельным окном, а не вкладкой панели (решение 3 августа 2026). Панель
/// шириной 270 точек и фиксированной высоты — это согласованное свойство
/// продукта, а не текущее состояние вёрстки: она висит поверх CRM весь рабочий
/// день. Список с фильтром и длительностями туда влезает только ценой
/// нечитаемых строк, а раздвинуть панель под историю значит отменить решение
/// M0 ради экрана, который открывают несколько раз в день.
///
/// Кнопок удаления здесь нет, и это тоже решение, а не недоделка. История нужна
/// в том числе как свидетельство при разборе жалобы, а свидетельство, которое
/// может убрать заинтересованная сторона, свидетельством не является. Записи
/// уходят только по сроку хранения, и срок задаёт администратор.
///
/// **Этап 4 плана по интерфейсу**, 6 августа 2026. До него окно было собрано на
/// системных умолчаниях: непрозрачный фон, `List`, отступы 16/10/3 мимо шкалы и
/// пустое состояние в одну серую строку. Три решения этого этапа:
///
/// - **стекло, как у панели и настроек.** Окно осталось бы единственным
///   непрозрачным из трёх, и это читается как забытое, а не как решение;
/// - **не `List`** — по той же причине, по которой в настройках нет `Form`:
///   системный список рисует непрозрачную подложку, и материал под ней не
///   виден. Терять от этого нечего: выбор строки здесь не значит ничего
///   (повтор набора живёт в своей кнопке), а страница ограничена двумя сотнями
///   строк на стороне выборки — ленивость не нужна;
/// - **дни отдельными заголовками.** Дата стояла в каждой строке, то есть
///   двадцать раз подряд одна и та же; в строке осталось время, а день ушёл
///   наверх группы, где его читают один раз.
struct CallHistoryWindowView: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.sectionSpacing) {
            filterBar
            content
            footer
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
        // `onAppear` здесь нет намеренно: срез перечитывает тот, кто открывает
        // окно (`showCallHistoryWindow`), до показа. Обновление списка после
        // того, как строки уже разложены, уводило прокрутку в конец — окно
        // встречало оператора самым старым звонком.
    }

    /// Фильтр — теми же кнопками, что выбор рабочего места в настройках.
    ///
    /// Не `Picker(.segmented)`: сегментированный стиль рисует непрозрачную
    /// подложку и на стекле выглядит вырезанным из другого окна. Выбранное
    /// отмечено акцентом там, где он есть, и обычной рамкой на Catalina —
    /// `compatProminentButtonStyle` разбирает это одним местом на всё
    /// приложение.
    private var filterBar: some View {
        HStack(spacing: Theme.Metrics.elementSpacing) {
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
            Spacer()
        }
        .font(.callout)
        // Мелкие кнопки, как на странице настроек. На обычном размере четыре
        // кнопки в ряд оказывались самым заметным, что есть в окне, — заметнее
        // самих звонков, ради которых его открыли.
        .controlSize(.small)
        // При выключенной истории фильтровать нечего и никогда не будет:
        // работающие кнопки над пустым окном обещают, что где-то за ними записи
        // всё-таки есть.
        .disabled(!model.settings.history.isEnabled)
    }

    /// Список или пустое состояние — на одном и том же слабом слое.
    ///
    /// Слой один на оба случая намеренно: если бы плашка появлялась только под
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
            VStack(alignment: .leading, spacing: Theme.Metrics.tightSpacing) {
                ForEach(days) { day in
                    Text(day.title)
                        .font(.footnote)
                        .compatForeground(Theme.Palette.textSecondary)
                        .padding(.horizontal, Theme.Metrics.elementSpacing)
                        .padding(.top, Theme.Metrics.tightSpacing)

                    ForEach(day.records) { record in
                        CallHistoryRow(record: record)
                    }
                }
            }
            .padding(Theme.Metrics.elementSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

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
                Button("Показать все") { model.historyFilter = .all }
                    .font(.callout)
            }
        }
        .padding(Theme.Metrics.contentPadding)
        .frame(maxWidth: Theme.Metrics.historyMinWidth / 2)
    }

    /// Записи есть, но текущий фильтр их не пропускает.
    private var isFilteredOut: Bool {
        model.historyFilter != .all && model.historyTotalCountUnfiltered > 0
    }

    private var emptyTitle: String {
        guard model.settings.history.isEnabled else {
            return "История звонков выключена"
        }
        if isFilteredOut {
            switch model.historyFilter {
            case .all: return "Звонков пока не было"
            case .incoming: return "Входящих в истории нет"
            case .outgoing: return "Исходящих в истории нет"
            case .missed: return "Пропущенных нет"
            }
        }
        return "Звонков пока не было"
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
        let total = model.historyTotalCountUnfiltered
        return "Под этот фильтр не попал ни один звонок из \(total)."
    }

    /// Подпись внизу говорит две вещи: сколько записей показано из скольких и
    /// сколько они живут. Второе — не украшение: человек, ищущий звонок
    /// полугодовой давности, должен узнать, что искать нечего, здесь, а не в
    /// поддержке.
    /// При выключенной истории подписи нет вовсе. «Записей: 0» и «Хранится 30
    /// дн.» под выключенной историей — два обещания подряд, и оба неверные:
    /// считать нечего и хранить нечего. Пустое состояние уже всё сказало.
    @ViewBuilder
    private var footer: some View {
        if model.settings.history.isEnabled {
            HStack(spacing: Theme.Metrics.elementSpacing) {
                Text(shownCount)
                Spacer()
                Text("Хранится \(model.settings.history.maximumAgeInDays) дн., дальше удаляется")
            }
            .font(.footnote)
            .compatForeground(Theme.Palette.textSecondary)
        }
    }

    private var shownCount: String {
        let shown = model.historyRecords.count
        let total = model.historyTotalCount
        if total > shown {
            return "Показаны последние \(shown) из \(total)"
        }
        return total == 1 ? "1 запись" : "Записей: \(total)"
    }

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
            HistoryDay(id: day, title: Self.dayTitle(day, calendar: calendar), records: grouped[day] ?? [])
        }
    }

    /// «Сегодня» и «Вчера» словами, остальное датой.
    ///
    /// Два дня, а не больше: «позавчера» человек уже переводит в дату сам, а
    /// «в среду» на третьей неделе истории означает четыре разных среды.
    private static func dayTitle(_ day: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: Date())
        if day == today { return "Сегодня" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return "Вчера"
        }
        // Год добавляется только когда он не этот: в пределах срока хранения
        // (30 дней по умолчанию) он всегда лишний, но срок задаёт
        // администратор, и на длинном он становится единственным различием.
        let formatter = calendar.isDate(day, equalTo: today, toGranularity: .year)
            ? dayFormatter
            : dayWithYearFormatter
        return formatter.string(from: day)
    }

    private static let dayFormatter = makeFormatter("d MMMM")
    private static let dayWithYearFormatter = makeFormatter("d MMMM yyyy")

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = format
        return formatter
    }
}

/// Строка истории.
///
/// Читается слева направо в том же порядке, в каком о звонке думают: кто,
/// когда, чем кончился. Повтор набора — справа, отдельной кнопкой, а не
/// нажатием по строке: нажатие по строке в списке означает «выбрать», и
/// звонок от него — это звонок, которого не хотели.
private struct CallHistoryRow: View {

    @EnvironmentObject private var model: AppModel

    let record: CallRecord

    private var canRedial: Bool { model.canPlaceCall && !record.number.isEmpty }

    var body: some View {
        HStack(spacing: Theme.Metrics.sectionSpacing) {
            CompatSymbol(name: record.direction == .incoming ? "phone.arrow.down.left.fill" : "phone.arrow.right")
                .compatForeground(record.isMissed ? Theme.Palette.failure : Theme.Palette.textSecondary)
                .compatAccessibilityLabel(record.direction == .incoming ? "Входящий" : "Исходящий")

            VStack(alignment: .leading, spacing: Theme.Metrics.hairSpacing) {
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
            // от длины причины отказа и не стоят на одной вертикали.
            VStack(alignment: .trailing, spacing: Theme.Metrics.hairSpacing) {
                Text(Self.timeFormatter.string(from: record.startedAt))
                    .compatMonospacedDigit()
                Text(outcome)
                    .font(.footnote)
                    .compatForeground(record.isMissed ? Theme.Palette.failure : Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: Theme.Metrics.historyOutcomeColumn, alignment: .trailing)

            Button {
                model.redial(record)
            } label: {
                // Не зелёная, хотя кнопка и звонит. Зелёный стоит в каждой
                // строке, то есть двадцать раз подряд, и рядом с ним пропадает
                // единственное красное пятно окна — значок пропущенного слева.
                // Цвет должен доставаться тому, что случается редко, а не тому,
                // что повторяется в каждой строке.
                CompatSymbol(name: "phone.fill")
                    .compatForeground(canRedial ? Theme.Palette.textSecondary : Theme.Palette.textTertiary)
                    // Подсветка живёт на самой иконке, а не на строке: строка
                    // не нажимается, и подсвечивать её целиком значило бы
                    // обещать действие, которого по ней нет.
                    .padding(Theme.Metrics.tightSpacing)
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
        .padding(.vertical, Theme.Metrics.tightSpacing)
        .padding(.horizontal, Theme.Metrics.elementSpacing)
    }

    /// Под именем — то, чем оно подтверждается: сам номер, если показано не
    /// его, профиль, с которого звонили, пометки перевода и конференции, а у
    /// несостоявшегося разговора — ещё и причина.
    ///
    /// **Причина стоит здесь, а не в правой колонке**, и это правка по живому
    /// окну. Справа она не помещалась: «отказ 503 service unavailable» ужимался
    /// до «отказ 503 service…», то есть до строки, по которой нельзя отличить
    /// занятого коллеги от неверного номера, — а ради этого различия причину и
    /// хранят. Слева ширина есть: там она стояла пустой ровно потому, что
    /// подзаголовок из номера и метки профиля короткий.
    ///
    /// У состоявшегося разговора причины нет: его итог — длительность, а
    /// «завершён» в каждой второй строке не сообщает ничего.
    private var subtitle: String {
        var parts: [String] = []
        if record.title != record.number, !record.number.isEmpty {
            parts.append(record.number)
        }
        if let label = record.profileLabel, !label.isEmpty {
            parts.append(label)
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
        if record.duration == nil, let reason = record.endReason, !reason.isEmpty {
            parts.append(reason.lowercased())
        }
        return parts.joined(separator: " · ")
    }

    /// Справа снизу — итог звонка одним словом.
    ///
    /// Короткий и предсказуемой длины: длинного здесь держать негде, а колонка
    /// обязана быть постоянной ширины ради выравнивания кнопок.
    private var outcome: String {
        if let duration = record.duration {
            return Self.duration(duration)
        }
        if record.endedAt == nil {
            return "идёт"
        }
        return record.isMissed ? "пропущен" : "без ответа"
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let rest = total % 60
        return String(format: "%d:%02d", minutes, rest)
    }

    /// Только время: день вынесен в заголовок группы, и повторять его в каждой
    /// строке значит двадцать раз подряд сообщить одно и то же.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
