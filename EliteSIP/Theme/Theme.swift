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
        /// Панель фиксированного размера, а не «по содержимому».
        ///
        /// Высота задана явно, и свободную вертикаль забирает клавиатура: иначе
        /// при заданных 500 точках окно оказалось бы наполовину пустым, а
        /// растянутые клавиши — это ещё и удобнее для попадания мышью.
        static let panelWidth: CGFloat = 280
        static let panelHeight: CGFloat = 500

        /// Окно входящего. Высота зависит от того, включено ли подтверждение
        /// цифрой: в макете это два разных состояния, 186 и 244 точки. Ряду
        /// цифр и подписи над ним нужно место, а без них тянуть окно нечем —
        /// пустая карточка выглядит недорисованной.
        static func incomingCallPanelSize(withDigitChallenge: Bool) -> CGSize {
            CGSize(width: 320, height: withDigitChallenge ? 244 : 186)
        }

        static let contentPadding: CGFloat = 12
        static let sectionSpacing: CGFloat = 8
        static let dialpadSpacing: CGFloat = 6

        /// Ниже этого клавиша не сжимается, даже если контента станет больше.
        static let dialpadButtonMinHeight: CGFloat = 36

        /// Отступ сверху, чтобы контент не лез под кнопки окна при скрытом
        /// заголовке.
        static let titleBarInset: CGFloat = 24

        /// Размер цифры на клавише и в поле номера.
        static let dialpadKeyFontSize: CGFloat = 20
        static let dialedNumberFontSize: CGFloat = 22
    }

    enum Radius {
        static let surface: CGFloat = 16
        static let control: CGFloat = 10
    }

    /// Начертания из макета.
    ///
    /// Заданы размером, а не именованным стилем (`.caption`, `.body`), потому
    /// что окно входящего фиксированного размера: Dynamic Type растянул бы
    /// текст, а расти окну некуда — оно и так плавающее и должно оставаться
    /// компактным. Для остальных экранов по-прежнему используются системные
    /// стили.
    enum Text {
        /// Подпись «Входящий вызов».
        static let incomingCaption = Font.system(size: 11)
        /// Номер звонящего.
        static let incomingNumber = Font.system(size: 24, weight: .medium, design: .rounded)
        /// Имя звонящего и указание под ним.
        static let incomingDetail = Font.system(size: 13)
        /// Цифра, которую надо нажать, — в тексте указания.
        static let incomingTarget = Font.system(size: 15)
        /// Цифра на кнопке-цели и на клавише набора.
        static let controlKey = Font.system(size: 20, design: .rounded)
        /// Надпись на кнопке.
        static let controlLabel = Font.system(size: 13, weight: .medium)
        /// Состояние регистрации в бейдже панели.
        static let panelStatus = Font.system(size: 13)
        /// Вторая строка бейджа — срок регистрации или время повтора.
        static let panelDetail = Font.system(size: 10)
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
