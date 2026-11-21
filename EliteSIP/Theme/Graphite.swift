import AppKit
import SwiftUI

/// Графитовая система Windows-клиента 1.0.4 — общий стандарт оформления.
///
/// Числа — из `Palette.Dark.xaml` и `Palette.Light.xaml` Windows-версии:
/// нейтральные серые поверхности без синего оттенка, вертикальный градиент,
/// светлый верхний край, мягкая тень, скругление 10. Кнопки звонка — те же
/// насыщенные зелёный и красный.
///
/// **Что остаётся от macOS.** Стекло: где оно включено, окно размывает то, что
/// за ним, а поверхности ложатся на него полупрозрачным графитом — тон и объём
/// Windows, материал macOS. Без стекла (ниже macOS 26 или по тумблеру)
/// поверхности непрозрачные, ровно как в Windows. Нативные контролы, сайдбары
/// и поведение окон не подменяются: графит красит то, что приложение рисует
/// само.
enum Graphite {

    /// Поверхности панели — ключи `Panel*Brush` Windows-клиента.
    enum Surface: CaseIterable {
        /// Шапка звонка и поле номера.
        case call
        /// Управляющие клавиши: удержание, микрофон, перевод, конференция.
        case control
        /// Плитки макросов — на ступень темнее управления.
        case macro
        case hover
        case macroHover
        case pressed
        /// Включённая клавиша (удержание, конференция).
        case selected
        /// Выключенный микрофон.
        case muted
        /// Капсула профиля и меню.
        case profile
        case profileHover
        /// Кнопка звонка и «Ответить».
        case answer
        /// «Завершить» и «Отклонить».
        case decline

        /// Остановки градиента сверху вниз: светлая тема, тёмная тема.
        fileprivate var stops: (light: [UInt32], dark: [UInt32]) {
            switch self {
            case .call: ([0xffffff, 0xe4e4e4], [0x3c3c3c, 0x303030])
            case .control: ([0xffffff, 0xe8e8e8], [0x363636, 0x2e2e2e])
            case .macro: ([0xe8e8e8, 0xdfdfdf], [0x292929, 0x242424])
            case .hover: ([0xffffff, 0xeeeeee], [0x3b3b3b, 0x323232])
            case .macroHover: ([0xececec, 0xe5e5e5], [0x2f2f2f, 0x292929])
            case .pressed: ([0xd4d4d4, 0xdedede], [0x222222, 0x282828])
            case .selected: ([0xc6c6c6, 0xb8b8b8], [0x505050, 0x424242])
            case .muted: ([0xf3cece, 0xe8b9b9], [0x653c3c, 0x513131])
            case .profile: ([0xffffff, 0xe9e9e9], [0x3b3b3b, 0x303030])
            case .profileHover: ([0xffffff, 0xefefef], [0x404040, 0x353535])
            case .answer: ([0x259B25, 0x168616, 0x0C700C], [0x259B25, 0x168616, 0x0C700C])
            case .decline: ([0xbd4545, 0xa43131], [0xbd4545, 0xa43131])
            }
        }

        /// Насыщенная кнопка: под ней белая надпись, и в стекле она остаётся
        /// непрозрачной — полупрозрачный зелёный над пёстрой CRM не читается.
        var isFilled: Bool { self == .answer || self == .decline }

        func gradient(dark: Bool) -> LinearGradient {
            let hex = dark ? stops.dark : stops.light
            return LinearGradient(
                gradient: Gradient(colors: hex.map(Graphite.color)),
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    /// Фон окна панели без обоев и без стекла: #F1F1F1 / #191919.
    static let windowBackground = dynamic(light: 0xf1f1f1, dark: 0x191919)

    /// Светлый верхний край поверхности: #B0FFFFFF / #20FFFFFF.
    static let edge = NSColor(name: nil) { appearance in
        isDark(appearance)
            ? NSColor(white: 1, alpha: 0x20 / 255)
            : NSColor(white: 1, alpha: 0xB0 / 255)
    }

    /// Радиус поверхностей панели — `PanelCornerRadius`.
    static let cornerRadius: CGFloat = 10

    /// Насыщенные цвета состояния для подписей — как у кнопок звонка.
    static let answerText = Color(dynamic(light: 0x107C10, dark: 0x6CCB5F))
    static let declineText = Color(dynamic(light: 0xC42B1C, dark: 0xFF99A4))

    static func color(_ hex: UInt32) -> Color {
        Color(nsColor(hex))
    }

    static func nsColor(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            nsColor(isDark(appearance) ? dark : light)
        }
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// Графитовая поверхность: градиент, светлый верхний край и мягкая тень.
private struct GraphiteSurface: ViewModifier {

    let surface: Graphite.Surface
    let cornerRadius: CGFloat
    let shadow: Bool

    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.compatBackground {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(surface.gradient(dark: scheme == .dark))
                    // В стекле графит полупрозрачный: тон и объём Windows,
                    // а под ними — материал macOS. Насыщенные кнопки — нет.
                    .opacity(Theme.Chrome.usesLiquidGlass && !surface.isFilled ? 0.62 : 1)
                // Светлый край только сверху — `BorderThickness="0,1,0,0"`.
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                surface.isFilled ? Color.white.opacity(0x30 / 255) : Color(Graphite.edge),
                                Color.clear,
                            ]),
                            startPoint: .top,
                            endPoint: .init(x: 0.5, y: 0.12)
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: Color.black.opacity(shadow ? 0.16 : 0),
                radius: 4.5,
                x: 0,
                y: 3
            )
        }
    }
}

extension View {

    /// Поверхность графитовой системы — см. `Graphite`.
    func graphiteSurface(
        _ surface: Graphite.Surface,
        cornerRadius: CGFloat = Graphite.cornerRadius,
        shadow: Bool = true
    ) -> some View {
        modifier(GraphiteSurface(surface: surface, cornerRadius: cornerRadius, shadow: shadow))
    }
}

/// Иконка Lucide — тот же набор, что в Windows-клиенте (`Assets/Lucide`).
struct LucideIcon: View {

    let name: String
    var size: CGFloat = 16

    var body: some View {
        CompatSymbol(name: "Lucide/\(name)", size: size)
    }
}
