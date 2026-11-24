import SwiftUI

/// Раздел «Очереди»: подписи раздач из Spark — только показ.
///
/// **С ноября 2026 правила заводятся в Spark** (вкладка «EliteSIP → Очереди»)
/// и приезжают в файле предустановок. Прежний словарь «номер очереди →
/// название» удалён: номер очереди в вызов не попадает, и словарь не сработал
/// ни разу. Править здесь нечего — правка на месте разошлась бы с панелью и
/// пропала бы со следующим файлом.
struct QueueSettingsTab: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsSection("Подписи раздач", icon: "users-round") {
            if model.settings.queues.queues.isEmpty {
                SettingsNote("Правил нет — раздача подписывается своим именем из вызова.")
            } else {
                SettingsColumns(model.settings.queues.queues, columns: 1) { queue in
                    QueueRow(queue: queue)
                }
            }
            SettingsHint("Правила заводятся в Spark, во вкладке «Очереди», и приезжают с предустановками.")
        }

        SettingsSection("Как называется входящий", icon: "bell") {
            RuleTable()
        }
    }
}

private struct QueueRow: View {

    let queue: AppSettings.QueueDirectory.Queue

    var body: some View {
        HStack(spacing: Theme.Metrics.elementSpacing) {
            Text(verbatim: queue.match)
                .font(.system(.footnote, design: .monospaced))
                .compatForeground(Theme.Palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(verbatim: queue.title)
                .frame(maxWidth: .infinity, alignment: .leading)
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
    /// совпадение: расходиться им нельзя.
    private let rules: [Rule] = [
        .init(condition: "Номер совпал с вашим добавочным",
              headline: "Вызов по сделке",
              detail: "номер не показывается"),
        .init(condition: "В вызове есть «X-Autoanswer: TRUE» или имя с внешним номером",
              headline: "Подпись по правилу выше или имя из вызова",
              detail: "и номер под ним"),
        .init(condition: "Раздача пришла без имени",
              headline: "Входящий из колл-центра",
              detail: "и номер под ним"),
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

                // Единственное, что таблицей не сказать: маска.
                Text("Российский мобильный входящего показывается под маской «+7**********» — в окне, в шапке разговора и в истории. Исходящие маской не закрываются.")
                    .font(.footnote)
                    .compatForeground(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Metrics.tightSpacing)
            }
        }
    }
}
