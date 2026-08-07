import AppKit
import CallGuard
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
///
/// `ObservableObject`, а не `@Observable`: макрос Observation требует macOS 14,
/// а срез x86_64 обязан работать на Catalina.
@MainActor
final class IncomingCallPanel: ObservableObject {

    @Published private var panel: NSPanel?

    /// Где окно было в прошлый раз — чтобы следующая позиция гарантированно
    /// отличалась и оператор не привыкал жать в одну точку.
    private var lastOrigin: CGPoint?

    /// Область текущего вызова: тот же экран и тот же отступ, по которым
    /// выбрана позиция. Хранится, чтобы возврат окна на экран после изменения
    /// размера считал границу той же, а не выбирал экран заново — курсор к
    /// этому моменту уже уехал.
    private var placement: IncomingCallPlacement?

    private var resizeObserver: Any?

    /// Защита текущего вызова. Живёт ровно столько, сколько висит окно.
    @Published private var guardSession: CallGuardSession?

    /// Слежение за курсором. Локальный монитор ловит движения над нашим окном,
    /// глобальный — подход к нему из чужого приложения; без второго честный
    /// оператор, работающий в CRM, выглядел бы как телепортирующийся кликер.
    private var localCursorMonitor: Any?
    private var globalCursorMonitor: Any?

    /// Что показать оператору, если нажатие не принято.
    @Published private(set) var refusal: String?

    var isVisible: Bool { panel != nil }

    /// Отчёт защиты по текущему вызову. После `hide` остаётся последним, чтобы
    /// его успел прочитать тот, кто разбирает завершение звонка.
    @Published private(set) var lastReport: CallGuardReport?

    func show(
        subject: IncomingCallSubject,
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

        // Borderless, а не titled со скрытым заголовком. Со вторым окно рисовало
        // поверх карточки собственную рамку и добавляло сверху полосу заголовка
        // — на экране это выглядело как тёмный прямоугольник вокруг панели и
        // пустая полоса внутри неё.
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: Theme.Metrics.incomingCallPanelWidth, height: 1)),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        // Окно не должно исчезать, когда оператор уходит в другое приложение —
        // это единственный индикатор того, что кто-то звонит.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow

        // contentViewController, а не contentView: так окно само подгоняется
        // под размер содержимого SwiftUI, и высоту не приходится держать
        // константой, которая расходится с вёрсткой при первом же изменении.
        panel.contentViewController = NSHostingController(
            rootView: IncomingCallView(
                subject: subject,
                challenge: session.challenge,
                isGuarded: policy.isEnabled,
                onAttempt: { [weak self] target in
                    self?.attempt(target: target, onAnswer: onAnswer)
                },
                onDecline: { [weak self] in
                    self?.hide()
                    onDecline()
                }
            )
            .environmentObject(self)
        )

        // Размер берём у собранного окна, а не из константы: высота зависит от
        // содержимого, и посчитанное по константе размещение вылезало бы за
        // край экрана ровно на разницу.
        //
        // `layoutIfNeeded` окна для этого мало: высоту считает SwiftUI внутри
        // `NSHostingController`, и до его прохода окно остаётся тем, каким его
        // создали, — в одну точку высотой. Позиция, выбранная под такое окно,
        // разрешает почти всю область по вертикали, и выросшее окно уходит за
        // край ровно на свою высоту.
        panel.contentViewController?.view.layoutSubtreeIfNeeded()
        if let fitting = panel.contentViewController?.view.fittingSize, fitting.height > 1 {
            panel.setContentSize(fitting)
        }
        panel.layoutIfNeeded()

        let placement = placement(policy: policy)
        self.placement = placement

        let origin = nextOrigin(forPanelSize: panel.frame.size, placement: placement, policy: policy)
        panel.setFrameOrigin(origin)
        lastOrigin = origin

        // Последний рубеж: любое изменение размера после размещения возвращает
        // окно внутрь области. Высота приезжает от содержимого и может прийти
        // позже — а окно, которое оператор не видит целиком, это не «мелкий
        // огрех оформления», а непринятый лид.
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            // Через `Task`, а не `MainActor.assumeIsolated`: тот появился в
            // macOS 13, а срез x86_64 обязан работать на Catalina.
            Task { @MainActor in self?.keepOnScreen() }
        }

        // Именно regardless: обычный orderFront активировал бы приложение.
        panel.orderFrontRegardless()

        self.panel = panel
        startWatchingCursor()
    }

    func hide() {
        stopWatchingCursor()
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        resizeObserver = nil
        placement = nil
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
    ///
    /// Источник у попытки всегда один — мышь. Клавиатурного приёма нет
    /// намеренно: он не оставлял защите ни одного признака живого человека, ни
    /// пути курсора, ни его отсутствия. «Отклонить» с клавиатуры при этом
    /// работает, то есть отказаться от вызова можно и без мыши.
    private func attempt(
        target: Character,
        onAnswer: @MainActor () -> Void
    ) {
        guard var session = guardSession else { return }

        let attempt = CallGuardAttempt(
            target: target,
            isSynthetic: Self.isCurrentEventSynthetic(),
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

    /// Область, в которой окну разрешено появиться на этом вызове.
    private func placement(policy: CallGuardPolicy) -> IncomingCallPlacement {
        let policy = policy.normalized
        let area = Self.currentScreen().visibleFrame
            .insetBy(dx: policy.screenMargin, dy: policy.screenMargin)
        return IncomingCallPlacement(bounds: area, minimumTravel: policy.minimumTravel)
    }

    /// Экран, на котором работает оператор.
    ///
    /// Под курсором, а не «главный»: рабочее место вполне может быть на втором
    /// мониторе, а `NSScreen.main` — это экран с ключевым окном, то есть чаще
    /// всего тот, где стоит CRM, а не тот, куда смотрит человек.
    ///
    /// Поиск идёт не одним `contains`: `CGRect.contains` не считает своими
    /// точки на верхней и правой кромке, а курсор в углу экрана — обычное дело.
    /// Запасной вариант — экран, к которому курсор ближе всего: он всегда
    /// осмысленнее, чем «главный».
    private static func currentScreen() -> NSScreen {
        let cursor = NSEvent.mouseLocation
        let screens = NSScreen.screens

        if let exact = screens.first(where: { $0.frame.contains(cursor) }) {
            return exact
        }
        if let nearest = screens.min(by: {
            distance(from: cursor, to: $0.frame) < distance(from: cursor, to: $1.frame)
        }) {
            return nearest
        }
        return NSScreen.main ?? NSScreen()
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    private func nextOrigin(
        forPanelSize size: CGSize,
        placement: IncomingCallPlacement,
        policy: CallGuardPolicy
    ) -> CGPoint {
        let policy = policy.normalized
        let area = placement.bounds

        guard policy.isEnabled, policy.isRandomPositionEnabled else {
            return CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2)
        }

        var generator = SystemRandomNumberGenerator()
        return placement.origin(forPanelSize: size, previous: lastOrigin, using: &generator)
    }

    /// Возвращает окно внутрь области, если оно оттуда вылезло.
    ///
    /// Позиция при этом остаётся случайной: рамка не выбирается заново, а
    /// вдвигается обратно ровно на столько, на сколько вылезла. Разбор — в
    /// `IncomingCallPlacement.contained`, здесь только применение.
    private func keepOnScreen() {
        guard let panel, let placement else { return }

        let corrected = placement.contained(panel.frame)
        guard corrected.origin != panel.frame.origin else { return }

        panel.setFrameOrigin(corrected.origin)
        // Запоминаем поправленную точку, а не исходную: следующий вызов обязан
        // отсчитывать смещение от того места, где окно оказалось на самом деле.
        lastOrigin = corrected.origin
    }
}
