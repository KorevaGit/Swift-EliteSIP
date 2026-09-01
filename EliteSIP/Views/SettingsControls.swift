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

    var body: some View {
        Group {
            LevelMeter(title: "Микрофон", level: levels.input)
            LevelMeter(title: "Приём", level: levels.output)
        }
    }
}

/// Один индикатор — микрофона или приёма — со своей подпиской.
///
/// Существуют затем же, зачем `LevelMeters`: подписываться на уровни должно
/// только то, что их рисует. В разделе «Звук» полоски стоят порознь, каждая под
/// своим ползунком, — пары там не получается, а читать `AudioLevels` прямо в
/// разделе значило бы перерисовывать всю страницу двадцать раз в секунду.
struct InputLevelMeter: View {

    @ObservedObject var levels: AudioLevels
    let title: LocalizedStringKey

    var body: some View { LevelMeter(title: title, level: levels.input) }
}

struct OutputLevelMeter: View {

    @ObservedObject var levels: AudioLevels
    let title: LocalizedStringKey

    var body: some View { LevelMeter(title: title, level: levels.output) }
}

/// Полоска уровня.
///
/// Нужна затем, чтобы оператор видел, что микрофон живой, до того как начнёт
/// говорить, — а не узнавал об этом от собеседника.
struct LevelMeter: View {

    let title: LocalizedStringKey
    let level: Float

    var body: some View {
        SettingsRow(title) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Palette.textTertiary.opacity(0.5))
                    Capsule()
                        .fill(color)
                        // Корень вместо самого уровня: слух логарифмический, и
                        // на линейной шкале обычная речь болтается у левого края.
                        .frame(width: geometry.size.width * CGFloat(sqrt(max(level, 0))))
                }
            }
            .frame(width: 160, height: 6)
        }
    }

    private var color: Color {
        // Красный только у самой шкалы: там начинается ограничение, и голос
        // хрипит независимо от кодека и сети.
        level > 0.95 ? Theme.Palette.failure : .accentColor
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
