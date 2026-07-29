import AppKit
import CallGuard
import Observation
import SwiftUI

/// Окно входящего вызова.
///
/// Это `NSPanel`, а не сцена SwiftUI, и на то три причины, каждая из которых
/// сама по себе достаточна:
///
/// * окно не должно забирать фокус — оператор в этот момент печатает в CRM,
///   и активация чужого приложения посреди набора недопустима
///   (`.nonactivatingPanel` + `orderFrontRegardless`);
/// * оно должно висеть поверх всех окон и на всех рабочих столах
///   (`level = .floating`, `collectionBehavior`);
/// * позиция задаётся точно и случайно, а `windowLevel` и
///   `defaultWindowPlacement` в SwiftUI появились только в macOS 15.
///
/// Панель же владеет и защитой: путь курсора виден только на уровне AppKit, а
/// решение о приёме принимает `CallGuardSession` из пакета — здесь остаётся
/// сбор фактов, там разбор.
@MainActor
@Observable
final class IncomingCallPanel {

    private var panel: NSPanel?

    /// Где окно было в прошлый раз — чтобы следующая позиция гарантированно
    /// отличалась и оператор не привыкал жать в одну точку.
    private var lastOrigin: CGPoint?

    /// Защита текущего вызова. Живёт ровно столько, сколько висит окно.
    private var guardSession: CallGuardSession?

    /// Слежение за курсором. Локальный монитор ловит движения над нашим окном,
    /// глобальный — подход к нему из чужого приложения; без второго честный
    /// оператор, работающий в CRM, выглядел бы как телепортирующийся кликер.
    private var localCursorMonitor: Any?
    private var globalCursorMonitor: Any?

    /// Цифры с клавиатуры.
    ///
    /// Локальный монитор, а не `keyboardShortcut` во вьюхе: окно намеренно не
    /// становится ключевым, и ярлыки SwiftUI в нём не срабатывают. Отсюда же
    /// граница возможного — клавиатура работает, когда EliteSIP впереди.
    /// Перехват клавиш из-под чужого приложения требует разрешения на
    /// мониторинг ввода; просить его ради ускорения на полсекунды в M3 не
    /// стали, вопрос отложен до M7 вместе с подписью и правами.
    private var keyMonitor: Any?

    /// Что показать оператору, если нажатие не принято.
    private(set) var refusal: String?

    var isVisible: Bool { panel != nil }

    /// Отчёт защиты по текущему вызову. После `hide` остаётся последним, чтобы
    /// его успел прочитать тот, кто разбирает завершение звонка.
    private(set) var lastReport: CallGuardReport?

    func show(
        callerNumber: String,
        callerName: String?,
        policy: CallGuardPolicy,
        onAnswer: @escaping @MainActor () -> Void,
        onDecline: @escaping @MainActor () -> Void
    ) {
        hide()

        var generator = SystemRandomNumberGenerator()
        let session = CallGuardSession(policy: policy, presentedAt: .now, using: &generator)
        guardSession = session
        lastReport = session.report
        refusal = nil

        let size = Theme.Metrics.incomingCallPanelSize(withDigitChallenge: session.challenge.hasChoice)
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        // Окно не должно исчезать, когда оператор уходит в другое приложение —
        // это единственный индикатор того, что кто-то звонит.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow

        panel.contentView = NSHostingView(
            rootView: IncomingCallView(
                callerNumber: callerNumber,
                callerName: callerName,
                challenge: session.challenge,
                activatesAt: session.activatesAt,
                isGuarded: policy.isEnabled,
                onAttempt: { [weak self] source, target in
                    self?.attempt(source: source, target: target, onAnswer: onAnswer)
                },
                onDecline: { [weak self] in
                    self?.hide()
                    onDecline()
                }
            )
            .environment(self)
        )

        // Размер окна берём после установки контента, а не из константы:
        // NSHostingView сообщает окну свой идеальный размер, а стиль .titled
        // добавляет сверху прозрачную полосу заголовка, так что настоящая рамка
        // выше нарисованной карточки. Если считать размещение по константе,
        // панель вылезет за верхний отступ экрана ровно на её высоту.
        let frameSize = panel.frame.size
        let origin = nextOrigin(forPanelSize: frameSize, policy: policy)
        panel.setFrameOrigin(origin)
        lastOrigin = origin

        // Именно regardless: обычный orderFront активировал бы приложение.
        panel.orderFrontRegardless()

        self.panel = panel
        startWatchingCursor()
        startWatchingKeys(onAnswer: onAnswer)
    }

    func hide() {
        stopWatchingCursor()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let guardSession {
            lastReport = guardSession.report
        }
        guardSession = nil
        refusal = nil
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Защита

    /// Разбирает попытку принять вызов.
    private func attempt(
        source: CallGuardAttempt.Source,
        target: Character,
        onAnswer: @MainActor () -> Void
    ) {
        guard var session = guardSession else { return }

        let attempt = CallGuardAttempt(
            source: source,
            target: target,
            isSynthetic: source == .mouse && Self.isCurrentEventSynthetic(),
            at: .now
        )
        let verdict = session.evaluate(attempt: attempt)
        guardSession = session
        lastReport = session.report

        switch verdict {
        case .accepted:
            hide()
            onAnswer()

        case .rejected(let reason):
            // Окно остаётся на месте: скрыть его в ответ на отклонённое
            // нажатие значило бы потерять лид из-за собственной защиты.
            refusal = reason.operatorMessage
        }
    }

    /// Похоже ли текущее событие на программно созданное.
    ///
    /// `CGEventSourceStateID` у настоящего нажатия — состояние комбинированного
    /// сеанса; `CGEvent.post` по умолчанию оставляет частный источник. Признак
    /// подделывается парой строк, поэтому он идёт в телеметрию, а барьером
    /// становится только по явной настройке.
    private static func isCurrentEventSynthetic() -> Bool {
        guard let event = NSApp.currentEvent?.cgEvent else { return false }
        let stateID = event.getIntegerValueField(.eventSourceStateID)
        return stateID != Int64(CGEventSourceStateID.combinedSessionState.rawValue)
    }

    // MARK: - Клавиатура

    private func startWatchingKeys(onAnswer: @escaping @MainActor () -> Void) {
        let targets = Set(guardSession?.challenge.targets ?? [])

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let characters = event.charactersIgnoringModifiers,
                  let digit = characters.first,
                  targets.contains(digit)
            else { return event }

            attempt(source: .keyboard, target: digit, onAnswer: onAnswer)
            return nil
        }
    }

    // MARK: - Курсор

    private func startWatchingCursor() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]

        localCursorMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.noteCursor(at: NSEvent.mouseLocation)
            return event
        }
        globalCursorMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            self?.noteCursor(at: NSEvent.mouseLocation)
        }
    }

    private func stopWatchingCursor() {
        for monitor in [localCursorMonitor, globalCursorMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        localCursorMonitor = nil
        globalCursorMonitor = nil
    }

    /// Считает только те перемещения, что случились рядом с окном.
    ///
    /// Рядом, а не строго внутри: рука подходит к кнопке снаружи, и обрезать
    /// путь по рамке значит требовать движений уже над самой кнопкой.
    private func noteCursor(at point: CGPoint) {
        guard var session = guardSession, let frame = panel?.frame else { return }
        guard frame.insetBy(dx: -80, dy: -80).contains(point) else { return }

        session.noteCursor(at: point)
        guardSession = session
    }

    // MARK: - Позиционирование

    private func nextOrigin(forPanelSize size: CGSize, policy: CallGuardPolicy) -> CGPoint {
        // Экран под курсором, а не «главный»: оператор может работать на втором.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let screen else { return .zero }

        let policy = policy.normalized
        let area = screen.visibleFrame.insetBy(dx: policy.screenMargin, dy: policy.screenMargin)

        guard policy.isEnabled, policy.isRandomPositionEnabled else {
            return CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2)
        }

        var generator = SystemRandomNumberGenerator()
        let placement = IncomingCallPlacement(bounds: area, minimumTravel: policy.minimumTravel)
        return placement.origin(forPanelSize: size, previous: lastOrigin, using: &generator)
    }
}
