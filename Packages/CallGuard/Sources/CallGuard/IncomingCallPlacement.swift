import CoreGraphics

/// Расчёт случайной позиции окна входящего вызова.
///
/// Первая и самая дешёвая мера защиты: кликер по фиксированным координатам
/// ломается об неё целиком. Чистая структура без AppKit и без глобального
/// состояния — генератор случайных чисел передаётся снаружи, поэтому поведение
/// воспроизводимо и проверяется тестами.
public struct IncomingCallPlacement: Sendable {

    /// Область, внутри которой окно вообще разрешено показывать.
    public var bounds: CGRect

    /// Минимальное расстояние от предыдущей позиции.
    public var minimumTravel: CGFloat

    /// Сколько раз пытаться попасть в требование по расстоянию, прежде чем
    /// взять лучшую из попыток. Без ограничения на маленьком экране цикл
    /// может не сойтись никогда.
    public var maximumAttempts: Int = 24

    public init(bounds: CGRect, minimumTravel: CGFloat, maximumAttempts: Int = 24) {
        self.bounds = bounds
        self.minimumTravel = minimumTravel
        self.maximumAttempts = maximumAttempts
    }

    /// Прямоугольник допустимых левых-нижних углов окна заданного размера.
    public func originBounds(forPanelSize size: CGSize) -> CGRect {
        CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: max(0, bounds.width - size.width),
            height: max(0, bounds.height - size.height)
        )
    }

    /// Возвращает рамку, целиком лежащую внутри разрешённой области.
    ///
    /// Существует потому, что размер окна на момент выбора позиции — обещание,
    /// а не факт. Высоту окну считает содержимое, и приехать она может позже
    /// выбора точки; окно, выросшее после размещения, уезжает за край ровно на
    /// разницу. Позиция при этом остаётся случайной: рамку не пересчитывают, а
    /// вдвигают обратно на столько, на сколько она вылезла.
    ///
    /// Окно крупнее области прижимается к её левому нижнему углу — тем же
    /// решением, что и в `origin`: лучше упереться в угол, чем разъехаться за
    /// две границы сразу.
    public func contained(_ frame: CGRect) -> CGRect {
        var origin = frame.origin

        if frame.width >= bounds.width {
            origin.x = bounds.minX
        } else {
            origin.x = min(max(origin.x, bounds.minX), bounds.maxX - frame.width)
        }

        if frame.height >= bounds.height {
            origin.y = bounds.minY
        } else {
            origin.y = min(max(origin.y, bounds.minY), bounds.maxY - frame.height)
        }

        return CGRect(origin: origin, size: frame.size)
    }

    public func origin(
        forPanelSize size: CGSize,
        previous: CGPoint?,
        using generator: inout some RandomNumberGenerator
    ) -> CGPoint {
        let allowed = originBounds(forPanelSize: size)

        // Окно шире или выше доступной области — прижимаем к углу, иначе
        // случайное смещение вытолкнет его за экран.
        guard allowed.width > 0 || allowed.height > 0 else {
            return CGPoint(x: allowed.minX, y: allowed.minY)
        }

        func candidate() -> CGPoint {
            CGPoint(
                x: allowed.minX + (allowed.width > 0
                    ? CGFloat.random(in: 0...allowed.width, using: &generator) : 0),
                y: allowed.minY + (allowed.height > 0
                    ? CGFloat.random(in: 0...allowed.height, using: &generator) : 0)
            )
        }

        guard let previous else { return candidate() }

        var best = candidate()
        var bestDistance = distance(best, previous)

        var attempt = 1
        while attempt < maximumAttempts, bestDistance < minimumTravel {
            let next = candidate()
            let nextDistance = distance(next, previous)
            if nextDistance > bestDistance {
                best = next
                bestDistance = nextDistance
            }
            attempt += 1
        }

        return best
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
