import SwiftUI

struct DialpadView: View {

    @EnvironmentObject private var model: AppModel

    /// Буквенных подписей нет намеренно: контактов в приложении нет, а на
    /// клавиатуре Asterisk буквы не значат ничего.
    private let rows: [[Character]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["*", "0", "#"],
    ]

    var body: some View {
        // VStack из HStack, а не LazyVGrid: сетка не умеет раздавать строкам
        // свободную высоту, а нам нужно, чтобы клавиатура забрала всю вертикаль,
        // которая осталась от остальных элементов.
        VStack(spacing: Theme.Metrics.dialpadSpacing) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: Theme.Metrics.dialpadSpacing) {
                    ForEach(row, id: \.self) { key in
                        DialpadKey(character: key) {
                            model.press(key)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct DialpadKey: View {

    let character: Character
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(String(character))
                .font(Theme.Text.controlKey)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: Theme.Metrics.dialpadButtonMinHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .themedControlSurface()
        .hoverHighlight()
        // Набор с физической клавиатуры — базовое ожидание от софтфона.
        .compatKeyboardShortcut(character, modifiers: [])
    }
}
