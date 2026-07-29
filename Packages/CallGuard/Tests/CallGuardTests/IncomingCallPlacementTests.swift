import CoreGraphics
import Testing
@testable import CallGuard

/// Первый слой защиты: окно не должно появляться дважды в одной точке.
///
/// До M3 у этой логики не было ни одного теста, хотя ломается об неё самый
/// частый инструмент — кликер по фиксированным координатам.
@Suite("Размещение окна входящего")
struct IncomingCallPlacementTests {

    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 916)
    private let panel = CGSize(width: 340, height: 228)

    private func placement(minimumTravel: CGFloat = 150) -> IncomingCallPlacement {
        IncomingCallPlacement(bounds: screen.insetBy(dx: 24, dy: 24), minimumTravel: minimumTravel)
    }

    @Test("Окно всегда остаётся внутри разрешённой области")
    func staysInsideBounds() {
        let placement = placement()
        var generator = SystemRandomNumberGenerator()
        var previous: CGPoint?

        for _ in 0..<500 {
            let origin = placement.origin(forPanelSize: panel, previous: previous, using: &generator)
            let frame = CGRect(origin: origin, size: panel)
            #expect(placement.bounds.contains(frame), "окно вылезло за отступ: \(frame)")
            previous = origin
        }
    }

    @Test("Позиции не повторяются и заметно расходятся")
    func spreadsAcrossScreen() {
        let placement = placement()
        var generator = SystemRandomNumberGenerator()
        var origins: [CGPoint] = []
        var previous: CGPoint?

        for _ in 0..<200 {
            let origin = placement.origin(forPanelSize: panel, previous: previous, using: &generator)
            origins.append(origin)
            previous = origin
        }

        #expect(Set(origins.map(\.x)).count > 150, "координаты почти не меняются — кликер по точке снова работает")

        // Требование по смещению выполняется не «в среднем», а на каждом шаге:
        // одной повторной позиции достаточно, чтобы мышечная память вернулась.
        let travels = zip(origins, origins.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        #expect(travels.allSatisfy { $0 >= 150 })
    }

    @Test("Тесная область не заставляет окно вылезти за край")
    func handlesTightBounds() {
        // Экран меньше окна: соблюсти смещение невозможно, и единственное
        // правильное поведение — прижаться к углу, а не уехать за границу.
        let tight = IncomingCallPlacement(
            bounds: CGRect(x: 10, y: 10, width: 200, height: 100),
            minimumTravel: 500
        )
        var generator = SystemRandomNumberGenerator()
        let origin = tight.origin(forPanelSize: panel, previous: CGPoint(x: 10, y: 10), using: &generator)
        #expect(origin == CGPoint(x: 10, y: 10))
    }

    @Test("Недостижимое требование по смещению не зацикливает расчёт")
    func doesNotHangOnImpossibleTravel() {
        // Смещение больше диагонали области: цикл обязан сдаться после
        // ограниченного числа попыток и взять лучшую из них.
        let placement = placement(minimumTravel: 10_000)
        var generator = SystemRandomNumberGenerator()
        let origin = placement.origin(
            forPanelSize: panel,
            previous: CGPoint(x: 100, y: 100),
            using: &generator
        )
        #expect(placement.bounds.contains(CGRect(origin: origin, size: panel)))
    }

    @Test("Один и тот же генератор даёт одну и ту же позицию")
    func isReproducible() {
        let placement = placement()
        var first = SequenceGenerator([11, 29, 47, 83])
        var second = SequenceGenerator([11, 29, 47, 83])

        #expect(
            placement.origin(forPanelSize: panel, previous: nil, using: &first)
                == placement.origin(forPanelSize: panel, previous: nil, using: &second)
        )
    }
}
