import AppKit
import SwiftUI

/// Управляющие элементы, общие для менеджерского окна и «Управления».
///
/// Лежат отдельно от обоих окон по той же причине, что и кирпичи раскладки в
/// `SettingsKit`: копия ползунка однажды разошлась бы с оригиналом шагом или
/// подписью, и заметили бы это не сразу.

/// Кнопка «Проверить обновления сейчас» (M7h).
///
/// Стоит в двух местах — «Диагностика» → «Сборка» у администратора и
/// «Техподдержка» у менеджера, — и это не то же самое место дважды.
/// Администратор разбирает жалобу на конкретной машине и хочет знать, дошёл ли
/// канал вообще; менеджер меньше интересуется механикой, но ровно он первым
/// слышит «у меня опять старая версия» и должен уметь проверить сам, не заводя
/// разговор с администратором ради одной кнопки.
///
/// Вынесена сюда по той же причине, что и `SettingSlider`: две копии этой
/// логики разошлись бы при первой же правке `UpdateService`, и заметили бы это
/// не сразу — искать надо было бы в двух вью одновременно.
/// «Проверить настройки сейчас» — то же, что `UpdateCheckRow`, но про панель.
///
/// Общим типом, а не двумя копиями в «Техподдержке» и «Управлении»: две
/// копии разойдутся при первой же правке слов, и оператор с администратором
/// увидят разные ответы на один вопрос.
///
/// Кнопка нужна не для удобства. Опрос канала идёт раз в два часа, и без неё
/// администратор, сменивший адрес АТС, не может убедиться, что правка доехала,
/// иначе как подождав эти два часа.
struct PresetCheckRow: View {

    let isChecking: Bool
    let result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.tightSpacing) {
            SettingsButtonsRow {
                Button("Проверить настройки сейчас") {
                    NSApp.sendAction(#selector(AppDelegate.checkPresetsNow(_:)), to: nil, from: nil)
                }
                .disabled(isChecking)

                if isChecking {
                    CompatSpinner()
                }
            }

            // Итог — строкой ПОД кнопкой, а не рядом с ней, и это правка
            // сломанной вёрстки. Рядом он стоял в `HStack`, где перенос текста
            // высоту ряда не увеличивает: длинный ответ — «Ошибка: <текст
            // системной ошибки сети>», «Обновление найдено, скачивается…» —
            // уезжал второй строкой на следующий блок. Все прочие пояснения
            // страницы давно живут `SettingsNote` ровно поэтому.
            //
            // Заодно ушёл прыжок кнопки: пока итог стоял в одном ряду с ней,
            // его появление и исчезновение двигало саму кнопку влево-вправо.
            if !isChecking, let result {
                SettingsNote(verbatim: result)
            }
        }
    }
}

/// «Вернуться в онлайн» — встаёт на место `PresetCheckRow` у машины в
/// оффлайне. Проверять настройки такой машине нечего: канал она не слушает.
struct PanelOnlineRow: View {

    let isChecking: Bool
    let result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.tightSpacing) {
            SettingsButtonsRow {
                Button("Вернуться в онлайн") {
                    NSApp.sendAction(#selector(AppDelegate.returnPanelOnline(_:)), to: nil, from: nil)
                }
                .disabled(isChecking)

                if isChecking {
                    CompatSpinner()
                }
            }
            SettingsNote("""
                Машина в оффлайне: настройки из панели не приходят. Возврат \
                заменит местные правки управляемых настроек настройками панели.
                """)
            if !isChecking, let result {
                SettingsNote(verbatim: result)
            }
        }
    }
}

/// Кнопка панели для машины с ключом: проверить настройки — или, в оффлайне,
/// вернуться в онлайн.
struct PanelSyncRow: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.isPanelOffline {
            PanelOnlineRow(isChecking: model.isCheckingPresets, result: model.presetCheckResult)
        } else {
            PresetCheckRow(isChecking: model.isCheckingPresets, result: model.presetCheckResult)
        }
    }
}

struct UpdateCheckRow: View {

    let isChecking: Bool
    let result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.tightSpacing) {
            SettingsButtonsRow {
                Button("Проверить обновления сейчас") {
                    NSApp.sendAction(#selector(AppDelegate.checkForUpdatesNow(_:)), to: nil, from: nil)
                }
                .disabled(isChecking)

                if isChecking {
                    // `ProgressView` — macOS 11, а x86_64 держит планку 10.15;
                    // CompatSpinner уже решает это в проекте, см. BackwardCompatibility.swift.
                    CompatSpinner()
                }
            }

            // Та же строка под кнопкой, что и у `PresetCheckRow`, и по той же
            // причине — разбор записан там.
            if !isChecking, let result {
                SettingsNote(verbatim: result)
            }
        }
    }
}

/// Пара индикаторов.
///
/// Живёт здесь, а не в «Диагностике», где была: те же уровни понадобились
/// менеджеру рядом с ползунками громкости — вслепую усиление не выставить.
///
/// Отдельная вьюха с собственной подпиской, а не два вызова прямо в разделе:
/// уровни обновляются двадцать раз в секунду, и подписываться на них должно
/// только то, что их показывает. Читай `AppModel.audioLevels` весь раздел
/// напрямую — перерисовывался бы вместе со списками и полями.
struct LevelMeters: View {

    @ObservedObject var levels: AudioLevels
    var inputTitle: LocalizedStringKey = "Микрофон"
    var outputTitle: LocalizedStringKey = "Приём"

    var body: some View {
        Group {
            LevelMeter(title: inputTitle, level: levels.input, peak: levels.inputPeak)
            LevelMeter(title: outputTitle, level: levels.output, peak: levels.outputPeak)
        }
    }
}

/// Шкала уровня.
///
/// Нужна затем, чтобы оператор видел, что микрофон живой, до того как начнёт
/// говорить, — а не узнавал об этом от собеседника.
///
/// С 0.1.41 — сегменты, а не тонкая полоска: в разделе «Звук» шкала отвечает
/// на голос постоянно, и по полоске в шесть точек высотой не было видно, где
/// речь, а где уже перегруз. Сегменты зелёные в рабочей зоне, жёлтые ближе к
/// верху и красные там, где начинается ограничение. Пик держится полсекунды —
/// короткий всплеск иначе проскакивает быстрее, чем глаз его заметит.
struct LevelMeter: View {

    let title: LocalizedStringKey
    let level: Float
    var peak: Float = 0

    private static let segments = 24

    var body: some View {
        SettingsRow(title) {
            HStack(spacing: 2) {
                ForEach(0..<Self.segments, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(fill(for: index))
                }
            }
            .frame(width: 200, height: 10)
            .compatAnimation(.linear(duration: 0.05), value: litSegments)
            .compatAccessibilityLabel(verbatim: "\(Int(displayLevel * 100)) %")
        }
    }

    /// Корень вместо самого уровня: слух логарифмический, и на линейной шкале
    /// обычная речь болтается у левого края.
    private var displayLevel: Float { sqrt(max(level, 0)) }

    private var litSegments: Int {
        Int((displayLevel * Float(Self.segments)).rounded())
    }

    private var peakSegment: Int {
        Int((sqrt(max(peak, 0)) * Float(Self.segments)).rounded()) - 1
    }

    private func fill(for index: Int) -> Color {
        let color = zoneColor(for: index)
        if index < litSegments { return color }
        if index == peakSegment, peakSegment >= litSegments { return color.opacity(0.7) }
        return Theme.Palette.textTertiary.opacity(0.35)
    }

    private func zoneColor(for index: Int) -> Color {
        let position = Double(index + 1) / Double(Self.segments)
        // Красный только у самой шкалы: там начинается ограничение, и голос
        // хрипит независимо от кодека и сети.
        if position > 0.92 { return Theme.Palette.failure }
        if position > 0.75 { return Theme.Palette.caution }
        return Color.green
    }
}

/// Не `private`: тот же ползунок стоит на менеджерской странице (M7c).
struct SettingSlider: View {

    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String?

    var body: some View {
        HStack {
            Slider(value: $value, in: range, step: step)
            Text(unit == nil ? String(format: "%.0f %%", value * 100) : "\(Int(value)) \(unit!)")
                .compatMonospacedDigit()
                .compatForeground(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
    }
}

/// Поле для миллисекунд.
///
/// Именно числом, а не ползунком: длительности тонов настраивают один раз и по
/// договорённости с той стороной, и «примерно 700» здесь бесполезно.
struct DelayField: View {

    @Binding var milliseconds: Int

    var body: some View {
        TextField("", value: $milliseconds, formatter: IntegerFormatter.shared)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .compatMonospacedDigit()
            .frame(width: 64)
            .labelsHidden()
    }
}
