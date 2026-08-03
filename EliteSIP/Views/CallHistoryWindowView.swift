import CallHistory
import SwiftUI

/// Окно «История звонков».
///
/// Отдельным окном, а не вкладкой панели (решение 3 августа 2026). Панель
/// шириной 280 точек и фиксированной высоты — это согласованное свойство
/// продукта, а не текущее состояние вёрстки: она висит поверх CRM весь рабочий
/// день. Список с фильтром и длительностями туда влезает только ценой
/// нечитаемых строк, а раздвинуть панель под историю значит отменить решение
/// M0 ради экрана, который открывают несколько раз в день.
///
/// Кнопок удаления здесь нет, и это тоже решение, а не недоделка. История нужна
/// в том числе как свидетельство при разборе жалобы, а свидетельство, которое
/// может убрать заинтересованная сторона, свидетельством не является. Записи
/// уходят только по сроку хранения, и срок задаёт администратор.
struct CallHistoryWindowView: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 380)
        // Список перечитывается на открытии окна, а не только по событию:
        // окно живёт между показами (`isReleasedWhenClosed = false`), и
        // показывать в нём вчерашний срез было бы хуже, чем не показывать
        // ничего.
        .onAppear { model.reloadHistory() }
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(CallHistoryStore.Filter.allCases, id: \.self) { item in
                Button {
                    model.historyFilter = item
                } label: {
                    Text(item.title)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                }
                // Тот же приём, что в «Управлении»: на macOS ниже 12
                // акцентного стиля нет вовсе, и выбранный фильтр иначе ничем
                // не отличался бы от остальных.
                .compatProminentButtonStyle(model.historyFilter == item)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if model.historyRecords.isEmpty {
            VStack(spacing: 6) {
                Spacer()
                Text(emptyTitle)
                    .compatForeground(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // `List`, а не `LazyVStack` в прокрутке: последний появился только
            // в macOS 11, а срез x86_64 обязан работать на Catalina. Ленивость
            // здесь всё равно ни при чём — страница ограничена двумя сотнями
            // строк на стороне выборки.
            List(model.historyRecords) { record in
                CallHistoryRow(record: record)
            }
        }
    }

    private var emptyTitle: String {
        guard model.settings.history.isEnabled else {
            return "История звонков выключена в «Управлении»."
        }
        switch model.historyFilter {
        case .all: return "Звонков пока не было."
        case .incoming: return "Входящих не было."
        case .outgoing: return "Исходящих не было."
        case .missed: return "Пропущенных нет."
        }
    }

    /// Подпись внизу говорит две вещи: сколько записей показано из скольких и
    /// сколько они живут. Второе — не украшение: человек, ищущий звонок
    /// полугодовой давности, должен узнать, что искать нечего, здесь, а не в
    /// поддержке.
    private var footer: some View {
        HStack(spacing: 8) {
            CompatSymbol(name: "clock")
                .compatForeground(.secondary)

            Text(shownCount)
                .font(.footnote)
                .compatForeground(.secondary)

            Spacer()

            Text("Хранится \(model.settings.history.maximumAgeInDays) дн., дальше удаляется")
                .font(.footnote)
                .compatForeground(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var shownCount: String {
        let shown = model.historyRecords.count
        let total = model.historyTotalCount
        if total > shown {
            return "Показаны последние \(shown) из \(total)"
        }
        return total == 1 ? "1 запись" : "Записей: \(total)"
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

    var body: some View {
        HStack(spacing: 10) {
            CompatSymbol(name: record.direction == .incoming ? "phone.arrow.down.left.fill" : "phone.arrow.right")
                .compatForeground(record.isMissed ? .red : .secondary)
                .compatAccessibilityLabel(record.direction == .incoming ? "Входящий" : "Исходящий")

            VStack(alignment: .leading, spacing: 1) {
                Text(record.title)
                    .compatMonospacedDigit()

                Text(subtitle)
                    .font(.footnote)
                    .compatForeground(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text(Self.timeFormatter.string(from: record.startedAt))
                    .compatMonospacedDigit()
                Text(outcome)
                    .font(.footnote)
                    .compatForeground(record.isMissed ? .red : .secondary)
            }

            Button {
                model.redial(record)
            } label: {
                CompatSymbol(name: "phone.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canPlaceCall || record.number.isEmpty)
            .compatHelp("Позвонить на \(record.number)")
            .compatAccessibilityLabel("Позвонить ещё раз")
        }
        .padding(.vertical, 3)
    }

    /// Под именем — то, чем оно подтверждается: сам номер, если показано не
    /// его, профиль, с которого звонили, и пометки перевода и конференции.
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
        return parts.joined(separator: " · ")
    }

    /// Справа снизу — итог звонка. Длительность, если разговор был; иначе
    /// прямая причина.
    private var outcome: String {
        if let duration = record.duration {
            return Self.duration(duration)
        }
        if record.endedAt == nil {
            return "идёт"
        }
        if record.isMissed {
            return "пропущен"
        }
        if let reason = record.endReason, !reason.isEmpty {
            return reason.lowercased()
        }
        return "без ответа"
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let rest = total % 60
        return String(format: "%d:%02d", minutes, rest)
    }

    /// Дата вместе со временем: история живёт неделями, и одно «14:32» без дня
    /// отвечает на вопрос «когда» ровно наполовину.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter
    }()
}
