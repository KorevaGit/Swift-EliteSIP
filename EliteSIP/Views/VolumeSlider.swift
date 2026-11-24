import AppKit
import SwiftUI

/// Ползунок громкости 0–200 %: скруглённая дорожка с подкрашенной частью,
/// круглый бегунок и метка на 100 %.
///
/// Одно поведение на панели и в настройках, как в Windows и Linux: КЦ
/// подстраивает громкость часто, и вернуться к норме должно быть делом одного
/// движения, а не прицеливания. При перетаскивании бегунок прилипает к 100 %,
/// двойной щелчок — сразу 100 %, колесо мыши — шаг 5 %.
///
/// Своим видом, а не системным `Slider`: у того на Catalina нет ни меток, ни
/// колеса, а мышь обрабатывает `VolumeSliderInput` — `NSView`, потому что
/// жесты SwiftUI 10.15 не различают двойной щелчок и начало перетаскивания.
struct VolumeSlider: View {

    @Binding var value: Double
    var range: ClosedRange<Double> = 0...2

    @Environment(\.isEnabled) private var isEnabled

    /// Положение под рукой. Настройка получает его после прохода обновления
    /// (см. `afterViewUpdate`), а ползунок читает отсюда — иначе на один кадр
    /// он возвращался бы к прежнему значению.
    @State private var draft: Double?

    static let step = 0.05

    /// Насколько близко к 100 % бегунок прилипает к метке.
    static let magnet = 0.075

    private static let thumb: CGFloat = 14
    private static let track: CGFloat = 4

    private var shown: Double { draft ?? value }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - Self.thumb, 1)
            let x = CGFloat(fraction(shown)) * width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.Palette.textTertiary.opacity(0.35))
                    .frame(height: Self.track)
                    .padding(.horizontal, Self.thumb / 2)

                Capsule()
                    .fill(Theme.Palette.textSecondary)
                    .frame(width: x + Self.track, height: Self.track)
                    .padding(.leading, Self.thumb / 2 - Self.track / 2)

                // Метка 100 % — там, куда прилипает бегунок.
                Rectangle()
                    .fill(Theme.Palette.textSecondary)
                    .frame(width: 1, height: 10)
                    .offset(x: Self.thumb / 2 + CGFloat(fraction(1)) * width - 0.5)

                Circle()
                    .fill(Color.white)
                    .compatOverlay { Circle().stroke(Theme.Palette.textSecondary, lineWidth: 1.5) }
                    .frame(width: Self.thumb, height: Self.thumb)
                    .shadow(color: Color.black.opacity(0.15), radius: 1, y: 0.5)
                    .offset(x: x)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .compatOverlay {
                VolumeSliderInput(
                    isEnabled: isEnabled,
                    inset: Self.thumb / 2,
                    onDrag: { set(Self.stick(value(atFraction: $0))) },
                    onReset: { set(1) },
                    onStep: { set(shown + Double($0) * Self.step) }
                )
            }
        }
        .frame(height: 20)
        .opacity(isEnabled ? 1 : Theme.Metrics.disabledOpacity)
        .compatAccessibilityLabel(verbatim: "\(Int((shown * 100).rounded())) %")
        // VoiceOver двигает его, как системный ползунок: вверх-вниз по 5 %.
        .compatAdjustable(isEnabled: isEnabled) { set(shown + Double($0) * Self.step) }
    }

    private func fraction(_ value: Double) -> Double {
        (value.clamped(to: range) - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func value(atFraction fraction: Double) -> Double {
        range.lowerBound + fraction.clamped(to: 0...1) * (range.upperBound - range.lowerBound)
    }

    private func set(_ new: Double) {
        let rounded = ((new / Self.step).rounded() * Self.step).clamped(to: range)
        guard rounded != shown else { return }
        draft = rounded
        afterViewUpdate {
            value = rounded
            if draft == rounded { draft = nil }
        }
    }

    /// Значение у метки 100 % — сама метка.
    static func stick(_ value: Double) -> Double {
        abs(value - 1) < magnet ? 1 : value
    }
}

private extension View {
    @ViewBuilder
    func compatAdjustable(isEnabled: Bool, step: @escaping (Int) -> Void) -> some View {
        if #available(macOS 11.0, *) {
            accessibilityElement(children: .ignore)
                .accessibilityAdjustableAction { direction in
                    guard isEnabled else { return }
                    switch direction {
                    case .increment: step(1)
                    case .decrement: step(-1)
                    @unknown default: break
                    }
                }
        } else {
            self
        }
    }
}

/// Мышь и клавиатура ползунка: перетаскивание, двойной щелчок, колесо и
/// стрелки. Фокус клавиатуры — только по Tab при полном доступе с клавиатуры
/// (`canBecomeKeyView`): щелчок мышью фокус не забирает, иначе панель поверх
/// CRM крала бы ввод у поля номера.
private struct VolumeSliderInput: NSViewRepresentable {

    let isEnabled: Bool
    let inset: CGFloat
    let onDrag: (Double) -> Void
    let onReset: () -> Void
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> InputView { InputView() }

    func updateNSView(_ view: InputView, context: Context) {
        view.isEnabled = isEnabled
        view.inset = inset
        view.onDrag = onDrag
        view.onReset = onReset
        view.onStep = onStep
    }

    final class InputView: NSView {
        var isEnabled = true
        var inset: CGFloat = 0
        var onDrag: (Double) -> Void = { _ in }
        var onReset: () -> Void = {}
        var onStep: (Int) -> Void = { _ in }

        /// Накопленная прокрутка трекпада: там события мелкие и частые, и шаг
        /// на каждое увёл бы ползунок до упора одним движением пальцев.
        private var scrolled: CGFloat = 0

        // Панель висит поверх CRM и активной бывает редко: первый щелчок
        // обязан двигать ползунок, а не только поднимать окно.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // Панель таскается за фон, и без этого перетаскивание бегунка
        // двигало бы окно.
        override var mouseDownCanMoveWindow: Bool { false }

        override var acceptsFirstResponder: Bool { isEnabled }
        override var canBecomeKeyView: Bool { isEnabled && NSApp.isFullKeyboardAccessEnabled }
        override var focusRingMaskBounds: NSRect { bounds }
        override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }

        override func keyDown(with event: NSEvent) {
            guard isEnabled else { return super.keyDown(with: event) }
            switch event.keyCode {
            case 123, 125: onStep(-1)      // ← ↓
            case 124, 126: onStep(1)       // → ↑
            default: super.keyDown(with: event)
            }
        }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            if event.clickCount == 2 {
                onReset()
            } else {
                drag(event)
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard isEnabled else { return }
            drag(event)
        }

        override func scrollWheel(with event: NSEvent) {
            guard isEnabled else { return super.scrollWheel(with: event) }
            let delta = event.scrollingDeltaY == 0 ? event.scrollingDeltaX : event.scrollingDeltaY
            guard event.hasPreciseScrollingDeltas else {
                if delta != 0 { onStep(delta > 0 ? 1 : -1) }
                return
            }
            scrolled += delta
            let threshold: CGFloat = 12
            while abs(scrolled) >= threshold {
                onStep(scrolled > 0 ? 1 : -1)
                scrolled -= scrolled > 0 ? threshold : -threshold
            }
            if event.phase == .ended || event.momentumPhase == .ended { scrolled = 0 }
        }

        private func drag(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let width = max(bounds.width - inset * 2, 1)
            onDrag(Double((point.x - inset) / width))
        }
    }
}

/// Ползунок громкости с процентами справа — строка настроек «Звук».
struct VolumePercentSlider: View {

    @Binding var value: Double
    var range: ClosedRange<Double> = 0...2

    var body: some View {
        HStack {
            VolumeSlider(value: $value, range: range)
            Text(String(format: "%.0f %%", value * 100))
                .compatMonospacedDigit()
                .compatForeground(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
    }
}
