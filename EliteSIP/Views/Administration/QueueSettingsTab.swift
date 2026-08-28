import SwiftUI

/// Раздел «Очереди»: справка о том, как приложение опознаёт входящий вызов.
///
/// **Раньше здесь был редактируемый словарь «номер очереди → название», и он
/// удалён 28 августа 2026.** Словарь сверял номер звонящего с номером очереди,
/// а боевой диалплан номер очереди в вызов не кладёт вовсе: раздача приходит
/// переводом, и в `From` стоит добавочный сотрудника колл-центра, отдавшего
/// лид. Сорок заполненных записей не совпадали ни с одним вызовом и совпасть не
/// могли — вживую проверено на снятых INVITE.
///
/// Раздел оставлен, но стал справкой. Причина не в том, что жалко места:
/// правила опознания вызова определяют, что оператор увидит на экране в момент,
/// когда решает, брать ли трубку, — и администратор, у которого спрашивают «а
/// почему тут номер, а тут название», должен иметь возможность прочитать ответ,
/// а не выяснять его по коду. Раньше он выяснял по коду.
///
/// Менять здесь нечего намеренно: все четыре правила выводятся из самого
/// вызова, и настройки, которой их можно испортить, больше нет.
struct QueueSettingsTab: View {

    var body: some View {
        SettingsSection("Как опознаётся входящий") {
            SettingsNote("""
                Проверки идут сверху вниз, срабатывает первая подошедшая. \
                Все четыре читают сам вызов — настраивать в них нечего.
                """)

            RuleTable()
        }

        SettingsSection("Номер собеседника") {
            SettingsNote("""
                Российский мобильный номер входящего показывается под маской \
                «+7**********» везде: в окне вызова, в шапке разговора и в истории. \
                Внутренние добавочные и городские номера видны как есть.
                """)

            SettingsNote("""
                Исходящие маской не закрываются: этот номер набрал сам оператор.
                """)
        }

        SettingsSection("Раздача") {
            SettingsNote("""
                Раздачу лида опознаёт заголовок «X-Autoanswer: TRUE» во входящем \
                INVITE — его ставит диалплан очереди. Это единственный прямой \
                признак: по номеру и имени раздача неотличима от звонка коллеги, \
                у обоих внутренний добавочный и подпись.
                """)

            SettingsNote("""
                Заголовок просит телефон снять трубку самостоятельно. EliteSIP \
                этого не делает и делать не будет: приём вызова обязан требовать \
                живого человека — в этом весь смысл защиты от автокликеров.
                """)

            SettingsNote("""
                Номер под названием раздачи — это добавочный сотрудника, \
                отдавшего лид, а не номер клиента и не номер очереди.
                """)
        }
    }
}

/// Таблица правил: условие слева, что увидит оператор справа.
///
/// Своей вёрсткой, а не четырьмя `SettingsNote` подряд: правила читаются как
/// список с двумя колонками, и разнесённые по абзацам они перестают читаться
/// вовсе — глазу не за что зацепиться, чтобы сравнить их между собой.
private struct RuleTable: View {

    /// Заголовок отдельно от пояснения, а не разметкой внутри строки.
    ///
    /// `Text` разбирает Markdown только с macOS 12, а срез x86_64 живёт с
    /// Catalina — там `**Вызов по сделке**` показался бы звёздочками. Две
    /// строки решают это без ветки по версии и заодно читаются лучше: главное
    /// стоит первым и одинаково у всех четырёх правил.
    private struct Rule: Identifiable {
        let id = UUID()
        let condition: LocalizedStringKey
        let headline: LocalizedStringKey
        let detail: LocalizedStringKey
    }

    private let rules: [Rule] = [
        .init(condition: "Номер звонящего совпал с вашим добавочным",
              headline: "Вызов по сделке",
              detail: "номер не показывается"),
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
            }
        }
    }
}
