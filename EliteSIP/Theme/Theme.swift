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

        /// Ширина окна входящего. Высота не задаётся — окно подгоняется под
        /// содержимое.
        ///
        /// Фиксированная высота здесь уже стоила бага: в макете два состояния,
        /// 186 и 244 точки, но зафиксировать их значит получить пустую полосу
        /// между именем звонящего и кнопками всякий раз, когда содержимого
        /// меньше расчётного — например когда сервер не прислал имя.
        static let incomingCallPanelWidth: CGFloat = 320

        static let contentPadding: CGFloat = 12
        static let sectionSpacing: CGFloat = 8
        static let dialpadSpacing: CGFloat = 6

        /// Ниже этого клавиша не сжимается, даже если контента станет больше.
        static let dialpadButtonMinHeight: CGFloat = 36

        /// Отступ сверху, чтобы контент не лез под кнопки окна при скрытом
        /// заголовке.
        static let titleBarInset: CGFloat = 24

        /// Размер номера в поле набора. Цифра на клавише теперь берётся из
        /// `Theme.Text.controlKey` — она же стоит на целях окна входящего.
        static let dialedNumberFontSize: CGFloat = 22
    }

    enum Radius {
        static let surface: CGFloat = 16
        static let control: CGFloat = 10
    }

    /// Начертания из макета.
    ///
    /// Заданы размером, а не именованным стилем (`.caption`, `.body`): окно
    /// входящего фиксированной ширины и висит поверх чужого интерфейса, а
    /// Dynamic Type на крупной настройке растянул бы его в половину экрана.
    /// Для остальных экранов по-прежнему используются системные стили.
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
        /// Третий уровень текста. Своя константа, потому что иерархический
        /// стиль `.tertiary` — это macOS 12, а `Color.tertiary` не существует
        /// вовсе ни на одной версии.
        static let tertiary = Color.secondary.opacity(0.55)
    }
}

/// Наложение поверх содержимого, а не замена фона: под ним может быть и
/// материал, и сплошная заливка, и подсветка должна работать одинаково.
private struct HoverHighlight: ViewModifier {

    let cornerRadius: CGFloat
    let isEnabled: Bool

    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .compatOverlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.primary.opacity(isHovered && isEnabled ? 0.12 : 0))
                    // Наложение обязано быть прозрачным для мыши, иначе оно же
                    // и съест нажатие, ради которого рисовалось.
                    .allowsHitTesting(false)
            }
            .onHover { isHovered = $0 }
            .compatAnimation(.easeOut(duration: 0.12), value: isHovered)
    }
}

extension View {

    /// Основная поверхность: стекло на macOS 26, материал ниже.
    ///
    /// Три ступени, а не две: `Material` из SwiftUI появился только в macOS 12,
    /// поэтому на Catalina и Big Sur тот же системный эффект берётся напрямую у
    /// AppKit. Плоской заливки нет ни на одной ступени.
    @ViewBuilder
    func themedSurface(cornerRadius: CGFloat = Theme.Radius.surface) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else if #available(macOS 12.0, *) {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self.background(
                CompatMaterial(material: .hudWindow, cornerRadius: cornerRadius)
            )
        }
    }

    /// Подсветка при наведении курсора.
    ///
    /// Нужна всем кнопкам со стилем `.plain`: он рисует только содержимое и
    /// никакой реакции на курсор не даёт. Для окна входящего это не косметика —
    /// оператор должен видеть, что попал в цель, до того как нажмёт, иначе
    /// промах по цифре выглядит как неработающая кнопка.
    ///
    /// Цвет берётся от `.primary`: в тёмной теме это белый и подсвечивает, в
    /// светлой — чёрный и притемняет. То есть верно в обеих.
    func hoverHighlight(
        cornerRadius: CGFloat = Theme.Radius.control,
        isEnabled: Bool = true
    ) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, isEnabled: isEnabled))
    }

    /// Поверхность управляющего элемента — то же самое, но радиусом поменьше.
    @ViewBuilder
    func themedControlSurface(cornerRadius: CGFloat = Theme.Radius.control) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else if #available(macOS 12.0, *) {
            self.background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            // `.quaternary` — тоже macOS 12. Ниже берётся тот же по смыслу
            // слабый слой поверх фона, но заданный явной прозрачностью.
            self.background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.primary.opacity(0.08))
            )
        }
    }
}
