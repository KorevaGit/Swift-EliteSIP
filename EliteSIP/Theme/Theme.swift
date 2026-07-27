import SwiftUI

/// Единственное место, где заданы размеры, радиусы и цвета.
///
/// Причина, по которой это отдельный слой, а не литералы по месту: приложение
/// живёт на macOS 14–26, и Liquid Glass есть только на 26. Разница должна быть
/// изолирована здесь, чтобы во вьюхах не было ни одного `#available`.
enum Theme {

    enum Metrics {
        /// Панель узкая и фиксированной ширины — это софтфон, а не окно почты.
        ///
        /// Габариты сознательно поджаты: окно висит поверх CRM весь рабочий
        /// день, и каждая лишняя точка ширины отъедает место у того, с чем
        /// оператор реально работает.
        static let panelWidth: CGFloat = 304
        static let panelMinHeight: CGFloat = 400

        static let incomingCallPanelSize = CGSize(width: 320, height: 186)

        static let contentPadding: CGFloat = 12
        static let sectionSpacing: CGFloat = 8
        static let dialpadSpacing: CGFloat = 6
        static let dialpadButtonHeight: CGFloat = 36

        /// Отступ сверху, чтобы контент не лез под кнопки окна при скрытом
        /// заголовке.
        static let titleBarInset: CGFloat = 24

        /// Размер цифры на клавише и в поле номера.
        static let dialpadKeyFontSize: CGFloat = 17
        static let dialedNumberFontSize: CGFloat = 20
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
