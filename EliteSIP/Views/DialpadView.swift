import SwiftUI

struct DialpadView: View {

    @Environment(AppModel.self) private var model

    /// Буквенных подписей нет намеренно: контактов в приложении нет, а на
    /// клавиатуре Asterisk буквы не значат ничего.
    private let keys: [Character] = [
        "1", "2", "3",
        "4", "5", "6",
        "7", "8", "9",
        "*", "0", "#",
    ]

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: Theme.Metrics.dialpadSpacing),
        count: 3
    )

    var body: some View {
        LazyVGrid(columns: columns, spacing: Theme.Metrics.dialpadSpacing) {
            ForEach(keys, id: \.self) { key in
                Button {
                    model.append(key)
                } label: {
                    Text(String(key))
                        .font(.system(size: 20, weight: .regular, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Metrics.dialpadButtonHeight)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .themedControlSurface()
                // Набор с физической клавиатуры — базовое ожидание от софтфона.
                .keyboardShortcut(KeyEquivalent(key), modifiers: [])
            }
        }
    }
}
