import CallHistory
import SwiftUI

/// Раздел «Очереди»: соответствия «номер раздачи → человеческое название».
///
/// Хранилище и чтение написаны с этапа 3 — окно входящего ставит это название
/// на главное место, — а редактора не было вовсе. До этапа 5 словарь
/// заполнялся правкой `settings.json` руками, то есть на всех живых машинах был
/// пуст, и вся иерархия окна входящего работала вхолостую.
///
/// Менеджеру раздел недоступен: название вызова определяет, как оператор
/// здоровается, и это решение колл-центра, а не рабочего места.
struct QueueSettingsTab: View {

    @EnvironmentObject private var model: AppModel

    /// Подсказки перечитываются при открытии раздела, а не на каждой
    /// перерисовке: запрос идёт в базу, а строки словаря правятся посимвольно.
    @State private var candidates: [NumberSighting] = []

    private var queues: Binding<[AppSettings.QueueDirectory.Queue]> {
        Binding(
            get: { model.settings.queues.queues },
            set: { model.settings.queues.queues = $0 }
        )
    }

    var body: some View {
        SettingsSection("Словарь") {
            SettingsOrderedList(
                items: queues,
                emptyNote: """
                    Словарь пуст: все вызовы выглядят обычными, и оператор не видит, \
                    из какой раздачи пришёл лид.
                    """,
                addTitle: "Добавить очередь",
                makeElement: { .init() }
            ) { queue in
                QueueRow(queue: queue)
            }

            SettingsNote("""
                Название встаёт в окне входящего на главное место — по нему оператор решает, \
                как здороваться. Номер сверяется с тем, что приходит в вызове; пробелы, скобки \
                и дефисы значения не имеют.
                """)
        }

        UnnamedNumbersSection(candidates: candidates, onAdopt: adopt)
            .onAppear { candidates = model.unnamedIncomingNumbers() }
    }

    /// Заводит строку с уже правильным номером. Название вписывает человек:
    /// придумать его за него нельзя, а пустая строка в словаре ничего не ломает
    /// — `isUsable` не пускает её в подстановку.
    private func adopt(_ sighting: NumberSighting) {
        model.settings.queues.queues.append(
            .init(number: sighting.number, title: "")
        )
        candidates = model.unnamedIncomingNumbers()
    }
}

private struct QueueRow: View {

    @Binding var queue: AppSettings.QueueDirectory.Queue

    var body: some View {
        HStack(spacing: Theme.Metrics.elementSpacing) {
            TextField("Номер", text: $queue.number)
                .labelsHidden()
                .font(.system(.body, design: .monospaced))
                .frame(width: 90)

            TextField("Название раздачи", text: $queue.title)
                .labelsHidden()
        }
    }
}

// MARK: - Подсказки

/// Номера, которые приходили на эту машину, но в словаре не названы.
///
/// Заведён потому, что редактора мало: номера очередей знает Asterisk
/// заказчика, а боевой сервер у нас на чтение. Ошибка в цифре, вписанной с
/// голоса, не проявляется ничем — вызов просто остаётся без названия, молча.
///
/// Автоматически в словарь не попадает ничего: иначе он зарос бы номерами,
/// пришедшими не из раздачи.
private struct UnnamedNumbersSection: View {

    let candidates: [NumberSighting]
    let onAdopt: (NumberSighting) -> Void

    var body: some View {
        SettingsSection("Приходили, но не названы") {
            if candidates.isEmpty {
                SettingsNote("""
                    Неназванных номеров нет. Либо словарь полон, либо на эту машину ещё не \
                    приходило вызовов с коротких номеров.
                    """)
            } else {
                // От колонки контролов, а не от края плашки: это не редактор,
                // а перечень подсказок, и строки в нём короткие. Настоящие
                // списки — словарь, макросы, шаги стука — занимают всю ширину
                // намеренно, им она идёт на пользу; здесь же разнобой левых
                // краёв был виден сразу.
                SettingsIndented {
                    SettingsColumns(candidates) { sighting in
                        row(sighting)
                    }
                }
            }

            SettingsNote("""
                Показаны короткие номера — раздачи и внутренние добавочные: полным телефонным \
                номером раздача не бывает, а список номеров клиентов в окне настроек \
                не нужен. Длинный номер по-прежнему можно вписать руками.
                """)
        }
    }

    private func row(_ sighting: NumberSighting) -> some View {
        HStack(spacing: Theme.Metrics.elementSpacing) {
            Button("Добавить") { onAdopt(sighting) }

            Text(sighting.number)
                .font(.system(.body, design: .monospaced))

            Text(subtitle(sighting))
                .font(.footnote)
                .compatForeground(Theme.Palette.textSecondary)

            Spacer(minLength: 0)
        }
    }

    private func subtitle(_ sighting: NumberSighting) -> String {
        "\(sighting.count) \(Self.callsWord(sighting.count)) · \(Self.formatter.string(from: sighting.lastCall))"
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM"
        formatter.locale = Locale(identifier: "ru_RU")
        return formatter
    }()

    private static func callsWord(_ count: Int) -> String {
        let tail = count % 100
        if (11...14).contains(tail) { return "вызовов" }
        switch count % 10 {
        case 1: return "вызов"
        case 2, 3, 4: return "вызова"
        default: return "вызовов"
        }
    }
}
