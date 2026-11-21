import CoreGraphics

/// Фирменный знак «Шампань» — контур, общий с Windows-клиентом.
///
/// Тот же вектор, что `BrandLogo.SymbolData` в Windows-версии: корона над
/// гарнитурой, в квадрате 32×32 с осью y вниз. Здесь он пересобран в
/// `CGPath` с осью y вверх. Иконку приложения рисует `Tools/makeAppIcon.swift`
/// по той же геометрии; правка пропорций — в обоих местах сразу.
enum BrandMark {

    /// Цвет контура: шампань, #D8C6A5.
    static let champagne = CGColor(srgbRed: 216 / 255, green: 198 / 255, blue: 165 / 255, alpha: 1)

    /// Толщина линии в единицах квадрата 32.
    static let lineWidth: CGFloat = 2.3

    /// Контур, вписанный в `rect` (квадрат 32 растягивается на него).
    static func path(in rect: CGRect) -> CGPath {
        let scale = min(rect.width, rect.height) / 32
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + (32 - y) * scale)
        }
        let path = CGMutablePath()
        // Корона.
        path.move(to: p(7, 12))
        for (x, y) in [(5, 5), (11, 8), (16, 3), (21, 8), (27, 5), (25, 12)] as [(CGFloat, CGFloat)] {
            path.addLine(to: p(x, y))
        }
        // Оголовье и правый микрофон.
        path.move(to: p(7, 16))
        path.addCurve(to: p(25, 16), control1: p(7, 12), control2: p(25, 12))
        path.addLine(to: p(25, 22))
        path.addQuadCurve(to: p(19, 28), control: p(25, 28))
        path.addLine(to: p(17, 28))
        // Левая сторона.
        path.move(to: p(7, 16))
        path.addLine(to: p(7, 21))
        path.addQuadCurve(to: p(13, 29), control: p(7, 27))
        // Чашки.
        path.move(to: p(4, 16))
        path.addQuadCurve(to: p(1, 20), control: p(1, 16))
        path.addQuadCurve(to: p(4, 24), control: p(1, 24))
        path.move(to: p(28, 16))
        path.addQuadCurve(to: p(31, 20), control: p(31, 16))
        path.addQuadCurve(to: p(28, 24), control: p(31, 24))
        return path
    }
}
