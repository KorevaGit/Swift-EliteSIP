import CallHistory
import SwiftUI

/// Раздел «Очереди»: словарь названий раздач и короткая справка о том, как
/// приложение опознаёт входящий вызов.
///
/// **Словарь вернулся 2 сентября 2026, после удаления 28 августа.** Удаляли его
/// за то, что на боевом диалплане он не совпадал ни с одним вызовом. Это и
/// сейчас так, но вывод из этого сделали слишком широкий: диалплан правит
/// заказчик, и подмену CallerID на номер очереди он волен вернуть. Разница с
/// прежним устройством в том, что теперь словарь ничего не решает в одиночку —
/// раздачу опознаёт заголовок `X-Autoanswer`, а словарь только уточняет
/// название. Пустой словарь — обычное состояние, а не недонастроенное.
///
/// **Справка ужата до таблицы.** Было три раздела и шесть абзацев прозы, в
/// которых тонуло единственное, за чем сюда приходят: какое правило сработает и
/// что оператор увидит. Всё, что не отвечало на этот вопрос, ушло в комментарии
/// по месту — читать их администратору незачем, а разбирающему код они нужны
/// ровно там, где он правит поведение.
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
        SettingsSection("Названия раздач") {
            SettingsOrderedList(
                items: queues,
                emptyNote: """
                    Пусто — и это рабочее состояние: раздачи подписываются общим \
                    заголовком. Записи нужны, только если ваш диалплан подставляет \
                    номер очереди в вызов.
                    """,
                addTitle: "Добавить очередь",
                makeElement: { .init() }
            ) { queue in
                QueueRow(queue: queue)
            }
        }

        if !candidates.isEmpty {
            SettingsSection("Приходили, но не названы") {
                SettingsIndented {
                    SettingsColumns(candidates) { sighting in
                        SightingRow(sighting: sighting, onAdopt: adopt)
                    }
                }
            }
        }

        SettingsSection("Как опознаётся входящий") {
            RuleTable()
        }
        .onAppear { candidates = model.unnamedIncomingNumbers() }
    }

    /// Заводит строку с уже правильным номером. Название вписывает человек:
    /// придумать его за него нельзя, а пустая строка в словаре ничего не ломает
    /// — `isUsable` не пускает её в подстановку.
    private func adopt(_ sighting: NumberSighting) {
        model.settings.queues.queues.append(.init(number: sighting.number, title: ""))
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

/// Номер, приходивший на эту машину и не названный в словаре.
///
/// Список только предлагает: номера очередей знает Asterisk заказчика, а боевой
/// сервер у нас на чтение, и вбитая с голоса ошибка в цифре не проявляется
/// ничем. Само в словарь не попадает ничего — иначе он зарос бы номерами,
/// пришедшими не из раздачи.
private struct SightingRow: View {

    let sighting: NumberSighting
    let onAdopt: (NumberSighting) -> Void

    var body: some View {
        HStack(spacing: Theme.Metrics.elementSpacing) {
            Text(verbatim: sighting.number)
                .font(.system(.footnote, design: .monospaced))

            Spacer(minLength: 0)

            Button("Добавить") { onAdopt(sighting) }
                .buttonStyle(.borderless)
        }
    }
}

/// Таблица правил: условие слева, что увидит оператор справа.
///
/// Своей вёрсткой, а не пятью `SettingsNote` подряд: правила читаются как
/// список с двумя колонками, и разнесённые по абзацам они перестают читаться
/// вовсе — глазу не за что зацепиться, чтобы сравнить их между собой.
private struct RuleTable: View {

    /// Заголовок отдельно от пояснения, а не разметкой внутри строки.
    ///
    /// `Text` разбирает Markdown только с macOS 12, а срез x86_64 живёт с
    /// Catalina — там `**Вызов по сделке**` показался бы звёздочками.
    private struct Rule: Identifiable {
        let id = UUID()
        let condition: LocalizedStringKey
        let headline: LocalizedStringKey
        let detail: LocalizedStringKey
    }

    /// Порядок здесь тот же, что в `IncomingCallSubject.init`, и это не
    /// совпадение: расходиться им нельзя. Свой добавочный проверяется первым —
    /// иначе администратор, вписавший его в словарь, получил бы «раздачу»
    /// вместо звонка по сделке.
    private let rules: [Rule] = [
        .init(condition: "Номер совпал с вашим добавочным",
              headline: "Вызов по сделке",
              detail: "номер не показывается"),
        .init(condition: "Номер есть в словаре выше",
              headline: "Название из словаря",
              detail: "и номер под ним"),
        .init(condition: "В вызове есть «X-Autoanswer: TRUE»",
              headline: "🔥Горячая раздача🔥",
              detail: "и добавочный отдавшего лид"),
        .init(condition: "Есть имя и номер длиннее шести цифр",
              headline: "🔥Горячая раздача🔥",
              detail: "мобильный под маской"),
        .init(condition: "Ничего из перечисленного",
              headline: "Имя звонящего",
              detail: "под ним номер"),
    ]

    var body: some View {
        SettingsIndented {
            VStack(alignment: .leading, spacing: Theme.Metrics.elementSpacing) {
                ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                    HStack(alignment: .top, spacing: Theme.Metrics.elementSpacing) {
                        // Номер правила — им же на него ссылаются в разговоре
                        // с поддержкой: «сработало второе».
                        Text("\(index + 1)")
                            .font(.footnote.monospacedDigit())
                            .compatForeground(Theme.Palette.textTertiary)
                            .frame(width: 14, alignment: .trailing)

                        Text(rule.condition)
                            .font(.footnote)
                            .compatForeground(Theme.Palette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.headline)
                                .font(.footnote.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)

                            Text(rule.detail)
                                .font(.footnote)
                                .compatForeground(Theme.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Единственное, что таблицей не сказать: маска. Одна строка
                // вместо прежнего раздела на два абзаца.
                Text("Российский мобильный входящего показывается под маской «+7**********» — в окне, в шапке разговора и в истории. Исходящие маской не закрываются.")
                    .font(.footnote)
                    .compatForeground(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Metrics.tightSpacing)
            }
        }
    }
}
