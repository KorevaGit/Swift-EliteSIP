import MediaCore
import SwiftUI

/// Раздел «Макросы»: кнопки, которые оператор жмёт в разговоре, и длительности
/// тонов, которыми они уходят.
///
/// Назывался «Тоны», пока в нём жила ещё и конференция. Та уехала в «АТС» —
/// код комнаты задаёт чужой сервер, а не мы, — и раздел остался о своём.
struct DTMFSettingsTab: View {

    @EnvironmentObject private var model: AppModel

    private var macros: Binding<[AppSettings.DTMFSettings.Macro]> {
        Binding(
            get: { model.settings.dtmf.macros },
            set: { model.settings.dtmf.macros = $0 }
        )
    }

    var body: some View {
        SettingsSection("Макросы") {
            SettingsOrderedList(
                items: macros,
                emptyNote: "Макросов нет. Кнопки появятся на панели во время разговора.",
                addTitle: "Добавить макрос",
                keepsSingleColumn: true,
                limit: AppSettings.DTMFSettings.maximumMacros,
                limitNote: "больше не влезает в панель",
                makeElement: { .init(title: "Новый", sequence: "") }
            ) { macro in
                MacroRow(macro: macro)
            }

            SettingsNote("""
                Порядок кнопок на панели — этот. Оператор целится в место, а не читает \
                подписи каждый раз, поэтому менять его стоит один раз при настройке, а не по \
                ходу работы.
                """)
        }

        SettingsSection("Запись") {
            // Формат заказчиком не задан — открытый вопрос 1 в README. Пока
            // принято привычное по телефонам, и об этом честно сказано здесь, а
            // не только в документации.
            SettingsNote("""
                Цифры, «*», «#» и A–D отправляются как тоны. Запятая — пауза; несколько запятых \
                подряд складываются. Пробелы и дефисы ни на что не влияют и нужны только для \
                читаемости.
                """)

            SettingsRow("Длина паузы") {
                DelayField(
                    milliseconds: Binding(
                        get: { model.settings.dtmf.pauseMilliseconds },
                        set: { model.settings.dtmf.pauseMilliseconds = max(100, $0) }
                    )
                )
            }
        }

        SettingsSection("Тон") {
            SettingsRow("Длительность") {
                DelayField(
                    milliseconds: Binding(
                        get: { model.settings.dtmf.toneMilliseconds },
                        set: { model.settings.dtmf.toneMilliseconds = max(40, $0) }
                    )
                )
            }

            SettingsNote("Минимум по RFC 4733 — 40 мс. Глухие голосовые меню лучше слышат 120.")

            SettingsRow("Пауза между тонами") {
                DelayField(
                    milliseconds: Binding(
                        get: { model.settings.dtmf.gapMilliseconds },
                        set: { model.settings.dtmf.gapMilliseconds = max(20, $0) }
                    )
                )
            }

            SettingsNote("Без паузы две одинаковые цифры подряд слышны как одна длинная.")
        }
    }
}

private struct MacroRow: View {

    @Binding var macro: AppSettings.DTMFSettings.Macro

    private var problem: String? {
        let unsupported = DTMFSequence.unsupportedCharacters(in: macro.sequence)
        if !unsupported.isEmpty {
            return "не тоны: \(String(unsupported))"
        }
        if !DTMFSequence(macro.sequence).hasTones {
            return "нет ни одного тона"
        }
        if macro.title.trimmingCharacters(in: .whitespaces).isEmpty {
            return "нет подписи"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.hairSpacing) {
            HStack(spacing: Theme.Metrics.elementSpacing) {
                TextField("Подпись", text: $macro.title)
                    .labelsHidden()
                    .frame(width: 120)
                TextField("Набор, например 2,,101#", text: $macro.sequence)
                    .labelsHidden()
                    .font(.system(.body, design: .monospaced))
            }

            // Негодный макрос на панели не появится, и молчать об этом нельзя:
            // оператор будет искать кнопку, которой нет.
            if let problem {
                CompatLabel(title: problem, symbol: "exclamationmark.triangle")
                    .font(.footnote)
                    .compatForeground(Theme.Palette.unsaved)
            } else {
                Text(DTMFSequence(macro.sequence).displayText)
                    .font(.footnote)
                    .compatForeground(Theme.Palette.textSecondary)
            }
        }
    }
}
