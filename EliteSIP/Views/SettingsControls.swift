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
        SettingsButtonsRow {
            Button("Проверить настройки сейчас") {
                NSApp.sendAction(#selector(AppDelegate.checkPresetsNow(_:)), to: nil, from: nil)
            }
            .disabled(isChecking)

            if isChecking {
                CompatSpinner()
            } else if let result {
                Text(verbatim: result)
                    .font(Theme.Text.statusDetail)
                    .compatForeground(Theme.Palette.textSecondary)
            }
        }
    }
}

struct UpdateCheckRow: View {

    let isChecking: Bool
    let result: String?

    var body: some View {
        SettingsButtonsRow {
            Button("Проверить обновления сейчас") {
                NSApp.sendAction(#selector(AppDelegate.checkForUpdatesNow(_:)), to: nil, from: nil)
            }
            .disabled(isChecking)

            if isChecking {
                // `ProgressView` — macOS 11, а x86_64 держит планку 10.15;
                // CompatSpinner уже решает это в проекте, см. BackwardCompatibility.swift.
                CompatSpinner()
            } else if let result {
                Text(verbatim: result)
                    .font(Theme.Text.statusDetail)
                    .compatForeground(Theme.Palette.textSecondary)
            }
        }
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
