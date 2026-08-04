import SwiftUI

/// Честная пометка о том, что ещё не сделано.
///
/// Нужна, чтобы скелет нельзя было принять за работающее приложение: кнопка,
/// которая выглядит рабочей и молча ничего не делает, хуже отсутствующей.
///
/// Живёт отдельным файлом, а не в панели: панель отдана оператору целиком, и
/// отладочных пометок в ней больше нет — остались только настройки и админка.
struct MilestoneNote: View {

    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        CompatLabel(title: text, symbol: "hammer.fill")
            .font(.footnote)
            .compatForeground(.secondary)
    }
}
