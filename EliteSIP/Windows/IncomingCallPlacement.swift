import CoreGraphics

/// Расчёт случайной позиции окна входящего вызова.
///
/// Вынесено в чистую структуру без AppKit и без глобального состояния:
/// генератор случайных чисел передаётся снаружи, поэтому поведение
/// воспроизводимо. В M3, когда рандомизация станет полноценной фичей, эта
/// структура уезжает в отдельный пакет вместе с тестами — сейчас у неё нет
/// покрытия, и это единственная непокрытая логика в M0.
struct IncomingCallPlacement {

    /// Область, внутри которой окно вообще разрешено показывать.
    /// В M3 сюда приедет пользовательский прямоугольник «не лезь на CRM».
    var bounds: CGRect

    /// Минимальное расстояние от предыдущей позиции.
    var minimumTravel: CGFloat

    /// Сколько раз пытаться попасть в требование по расстоянию, прежде чем
    /// взять лучшую из попыток. Без ограничения на маленьком экране цикл
    /// может не сойтись никогда.
    var maximumAttempts: Int = 24

    /// Прямоугольник допустимых левых-нижних углов окна заданного размера.
    func originBounds(forPanelSize size: CGSize) -> CGRect {
        CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: max(0, bounds.width - size.width),
            height: max(0, bounds.height - size.height)
        )
    }

    func origin(
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
