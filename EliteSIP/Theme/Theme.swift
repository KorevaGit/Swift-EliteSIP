import SwiftUI

/// Единственное место, где заданы размеры, радиусы и цвета.
///
/// Причина, по которой это отдельный слой, а не литералы по месту: приложение
/// живёт на macOS 14–26, и Liquid Glass есть только на 26. Разница должна быть
/// изолирована здесь, чтобы во вьюхах не было ни одного `#available`.
enum Theme {

    enum Metrics {
        /// Панель узкая и фиксированной ширины — это софтфон, а не окно почты.
        static let panelWidth: CGFloat = 380
        static let panelMinHeight: CGFloat = 560

        static let incomingCallPanelSize = CGSize(width: 340, height: 196)

        static let contentPadding: CGFloat = 16
        static let sectionSpacing: CGFloat = 14
        static let dialpadSpacing: CGFloat = 8
        static let dialpadButtonHeight: CGFloat = 46

        /// Отступ сверху, чтобы контент не лез под кнопки окна при скрытом
        /// заголовке.
        static let titleBarInset: CGFloat = 28
    }

    enum Radius {
        static let surface: CGFloat = 16
        static let control: CGFloat = 10
    }

    enum Palette {
        static let answer = Color.green
        static let decline = Color.red
        static let registered = Color.green
        static let connecting = Color.orange
        static let offline = Color.secondary
        static let failure = Color.red
    }
}

extension View {

    /// Основная поверхность: стекло на macOS 26, материал на 14–15.
    @ViewBuilder
    func themedSurface(cornerRadius: CGFloat = Theme.Radius.surface) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: .rect(cornerRadius: cornerRadius))
        }
    }

    /// Поверхность управляющего элемента — то же самое, но радиусом поменьше.
    @ViewBuilder
    func themedControlSurface(cornerRadius: CGFloat = Theme.Radius.control) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.quaternary.opacity(0.6), in: .rect(cornerRadius: cornerRadius))
        }
    }
}
