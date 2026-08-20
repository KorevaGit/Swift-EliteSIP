import MediaCore
import SwiftUI

/// Раздел «Клавиши»: кнопки, которые оператор жмёт в разговоре, и длительности
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
        SettingsSection("Клавиши") {
            SettingsOrderedList(
                items: macros,
                emptyNote: "Клавиш нет. Они появятся на панели во время разговора.",
                addTitle: "Добавить клавишу",
                keepsSingleColumn: true,
                limit: AppSettings.DTMFSettings.maximumMacros,
                limitNote: "больше не влезает в панель",
                // Новая клавиша заводится помеченной как перевод: у заказчика
                // все клавиши — коды перевода, и снимать галочку в редком
                // обратном случае дешевле, чем ставить её каждый раз. Умолчание
                // самого поля при чтении файла осталось прежним — «нет»: там оно
                // означает «прежняя версия не спрашивала», а не утверждение о
                // звонке.
                makeElement: {
                    .init(
                        title: NSLocalizedString("Новый", comment: "подпись только что заведённой клавиши"),
                        sequence: "",
                        transfersCall: true
                    )
                }
            ) { macro in
                MacroRow(macro: macro)
            }

            SettingsNote("""
                Порядок кнопок на панели — этот. Оператор целится в место, а не читает \
                подписи каждый раз, поэтому менять его стоит один раз при настройке, а не по \
                ходу работы.
                """)

            SettingsRow("В ряду") {
                SettingSlider(
                    value: Binding(
                        get: { Double(model.settings.dtmf.macroColumns) },
                        set: { model.settings.dtmf.macroColumns = Int($0) }
                    ),
                    range: AppSettings.DTMFSettings.columnRange.asDouble,
                    step: 1,
                    unit: NSLocalizedString("шт.", comment: "единица: число клавиш в ряду")
                )
            }

            SettingsRow("Высота клавиши") {
                Picker("", selection: Binding(
                    get: { model.settings.dtmf.macroHeightIsManual },
                    set: { model.settings.dtmf.macroHeightIsManual = $0 }
                )) {
                    Text("Авто").tag(false)
                    Text("Вручную").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
            }

            if model.settings.dtmf.macroHeightIsManual {
                SettingsRow("Высота") {
                        SettingSlider(
                        value: Binding(
                            get: { Double(model.settings.dtmf.macroHeight) },
                            set: { model.settings.dtmf.macroHeight = Int($0) }
                        ),
                        range: AppSettings.DTMFSettings.heightRange.asDouble,
                        step: 2,
                        unit: NSLocalizedString("тчк", comment: "единица: точки экрана")
                    )
                }
            }

            SettingsNote("""
                Ширина панели задана, поэтому выбор простой: меньше клавиш в ряду — шире \
                каждая. В режиме «Авто» высота клавиши считается по самой длинной подписи \
                при нынешней ширине и меняется вместе с ними; «Вручную» нужен там, где важно \
                именно заданное число — например чтобы две машины выглядели одинаково при \
                разных подписях. Каждый лишний ряд растит панель вниз.
                """)

            SettingsNote("""
                «Переводит звонок» ставьте у кодов перевода — приложение само их не узнаёт. \
                Помеченная клавиша оставляет в истории пометку «перевод», и по ней потом \
                разбирают, куда делся клиент. Состояние линии при этом всё равно ведёт АТС: \
                на экране останется прежний собеседник.
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
            return String(
                format: NSLocalizedString("не тоны: %@", comment: "почему клавиша негодна"),
                String(unsupported)
            )
        }
        if !DTMFSequence(macro.sequence).hasTones {
            return NSLocalizedString("нет ни одного тона", comment: "почему клавиша негодна")
        }
        if macro.title.trimmingCharacters(in: .whitespaces).isEmpty {
            return NSLocalizedString("нет подписи", comment: "почему клавиша негодна")
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

                // Признак ставит человек: что делает код на этой АТС, по самому
                // коду не видно — `*02` на боевом сервере это Attended
                // Transfer, а на другом там что угодно.
                Toggle("Переводит звонок", isOn: $macro.transfersCall)
                    .compatSwitchToggle()
                    .fixedSize()
            }

            // Негодный макрос на панели не появится, и молчать об этом нельзя:
            // оператор будет искать кнопку, которой нет.
            if let problem {
                CompatLabel(verbatim: problem, symbol: "exclamationmark.triangle")
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
