import Foundation

/// Пиковые уровни в обе стороны для индикатора.
///
/// Отдельный наблюдаемый объект, а не пара свойств `AppModel`, и причина
/// техническая. `ObservableObject` не различает, какое свойство изменилось: он
/// шлёт один `objectWillChange` на всех. Уровни обновляются двадцать раз в
/// секунду, то есть держи их `AppModel` — и панель софтфона перерисовывалась бы
/// двадцать раз в секунду весь разговор, хотя уровней она не показывает вовсе;
/// их видно только на вкладке «Звук» в настройках.
///
/// До перехода на Catalina этого вопроса не было: `@Observable` из macOS 14
/// отслеживает обращения к каждому свойству по отдельности, и лишние
/// перерисовки отсекались сами. Здесь ту же изоляцию приходится проводить
/// руками — по границе «что меняется часто».
@MainActor
final class AudioLevels: ObservableObject {

    @Published private(set) var input: Float = 0
    @Published private(set) var output: Float = 0

    /// Пики для шкалы: держатся полсекунды, потом опускаются к текущему
    /// уровню. Короткий всплеск — хлопок, «п» в микрофон — иначе проскакивает
    /// быстрее, чем глаз его заметит.
    @Published private(set) var inputPeak: Float = 0
    @Published private(set) var outputPeak: Float = 0

    private var inputPeakAt = Date.distantPast
    private var outputPeakAt = Date.distantPast
    private static let peakHold: TimeInterval = 0.5

    func update(input: Float, output: Float) {
        let now = Date()
        let inputPeak = Self.peak(self.inputPeak, at: &inputPeakAt, level: input, now: now)
        let outputPeak = Self.peak(self.outputPeak, at: &outputPeakAt, level: output, now: now)
        // Сравнение перед записью не лишнее: в тишине оба уровня равны нулю
        // подряд много тактов, и без этой проверки индикатор всё равно просил
        // бы перерисовку двадцать раз в секунду.
        guard input != self.input || output != self.output
            || inputPeak != self.inputPeak || outputPeak != self.outputPeak else { return }
        self.input = input
        self.output = output
        self.inputPeak = inputPeak
        self.outputPeak = outputPeak
    }

    func reset() {
        inputPeakAt = .distantPast
        outputPeakAt = .distantPast
        update(input: 0, output: 0)
    }

    private static func peak(_ current: Float, at time: inout Date, level: Float, now: Date) -> Float {
        if level >= current || now.timeIntervalSince(time) > peakHold {
            time = now
            return level
        }
        return current
    }
}
