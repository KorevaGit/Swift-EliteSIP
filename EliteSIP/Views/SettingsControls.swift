import SwiftUI

/// Управляющие элементы, общие для менеджерского окна и «Управления».
///
/// Лежат отдельно от обоих окон по той же причине, что и кирпичи раскладки в
/// `SettingsKit`: копия ползунка однажды разошлась бы с оригиналом шагом или
/// подписью, и заметили бы это не сразу.

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
