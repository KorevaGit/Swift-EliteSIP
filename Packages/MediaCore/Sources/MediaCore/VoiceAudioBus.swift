import AVFoundation
import Compat
import Foundation

// не переводится: арбитраж маршрута — журнал.

/// Один аудиотракт на приложение, который берут по очереди.
///
/// **Зачем.** Микрофон, выход и обработка голоса у оператора одни, а разговоров
/// до трёх, и активная аудиолиния всегда одна (`docs/lines.md`). Раньше это
/// выражалось объектом `VoiceAudioEngine` на каждый звонок: фоновые линии
/// держали свои остановленные движки, активная — работающий. Работало, но
/// стоило падения.
///
/// 6 августа 2026 приложение упало после отбоя: `-[AVAudioEngine dealloc]`
/// разбирал узел ввода-вывода ровно тогда, когда приватная очередь
/// `AVAudioIOUnit` выполняла отложенный блок слушателя свойств этого узла.
/// Уведомления ставит наша же остановка — выключение обработки голоса. Пока
/// движок создавался и уничтожался на каждый звонок, разбор приходился ровно на
/// виток отбоя, а дождаться очереди AVFAudio нечем: она приватная.
///
/// Шина разводит эти два момента во времени. Разговор идёт на движке, который
/// живёт дольше звонка, — в отбое не разбирается ничего. А освобождение,
/// которое всё-таки нужно (см. `scheduleRetirement`: **только** оно возвращает
/// AirPods из режима связи), происходит через секунду после того, как тракт
/// освободили, на своей очереди и только если его никто не забрал обратно.
/// Штатному образу жизни `AVAudioEngine` это не противоречит: «stopping the
/// engine releases the resources allocated by prepare» (`AVAudioEngine.h`), и
/// между звонками движок именно остановлен, а не выброшен.
///
/// **Почему отдельный тип, а не поле в `MediaSession`.** Владение — это
/// решение, а не действие, и его надо проверять тестом. Ошибка, ради которой
/// он написан, выглядит так: снятая линия останавливает тракт, который секунду
/// назад забрала другая, живая. С объектом-на-звонок такое было невозможно по
/// построению, с общим движком это первая же ошибка, которую сделает любой
/// новый путь — отложенный `deinit`, запоздавший обработчик, повторный отбой.
/// Поэтому остановка требует предъявить тот же ключ, с которым тракт брали.
public final class VoiceAudioBus: @unchecked Sendable {

    /// Ключ владельца. Ссылочная тождественность, а не имя: линии приходят и
    /// уходят, а совпадение по Call-ID означало бы, что новая сессия той же
    /// линии может остановить предыдущую.
    public typealias Token = ObjectIdentifier

    /// Обработчики разговора. Переезжают вместе с владением.
    public struct Handlers: Sendable {
        public var diagnostic: (@Sendable (String) -> Void)?
        public var event: (@Sendable (VoiceAudioEngine.Event) -> Void)?
        public var encodedFrame: (@Sendable (Data) -> Void)?
        public var decodedSamples: (@Sendable ([Int16]) -> Void)?
        public var needsFrame: (@Sendable () -> VoiceAudioEngine.PlaybackFrame?)?

        public init() {}
    }

    /// Текущий движок. Заменяется на свежий, когда тракт освобождают, — см.
    /// `scheduleRetirement`. Под замком, потому что читают его и владелец, и
    /// очередь замены.
    private let current: UnfairLock<VoiceAudioEngine>

    /// Очередь смены владельца. Последовательная: захват и отпускание не должны
    /// наложиться, а захват — это остановка, перенастройка и запуск подряд, до
    /// восьми десятых секунды на открытии устройства. Держать это время
    /// `os_unfair_lock` нельзя, поэтому ключ живёт под своим замком, а порядок
    /// операций обеспечивает очередь.
    private let gate = DispatchQueue(label: "com.elite.EliteSIP.audio-bus")
    private let ownership = UnfairLock(initialState: AudioOwnership())

    /// Отложенная замена движка. Трогается только на `gate`.
    private var retirement: DispatchWorkItem?
    /// Настройки последнего разговора: под них собирается сменный движок, и по
    /// ним же решается, надо ли вообще его менять. Только на `gate`.
    private var lastConfiguration: VoiceAudioEngine.Configuration?

    public init(engine: VoiceAudioEngine) {
        current = UnfairLock(initialState: engine)
    }

    public convenience init(configuration: VoiceAudioEngine.Configuration = .init()) throws {
        self.init(engine: try VoiceAudioEngine(configuration: configuration))
    }

    /// Кто держит тракт сейчас. Нужен фоновым линиям: у них своего движка
    /// больше нет, и «мой ли это звук» — единственный способ не тронуть чужой.
    public func isOwner(_ token: Token) -> Bool {
        ownership.withLock { $0.isOwner(token) }
    }

    public var isBusy: Bool { ownership.withLock { $0.isBusy } }

    /// Забирает тракт себе и запускает его.
    ///
    /// Прежний владелец отпускается здесь же и до запуска, а не оставляется на
    /// совесть вызывающего. Порядок обязателен и стоил отдельного разбора в
    /// `docs/lines.md`: два запущенных `VoiceProcessingIO` на одном устройстве
    /// делят его между собой, а Bluetooth-гарнитуру держат в режиме связи всё
    /// время, пока жив хоть один.
    public func claim(
        _ token: Token,
        configuration: VoiceAudioEngine.Configuration,
        handlers: Handlers
    ) throws {
        try gate.sync {
            // Замена движка отменяется: он снова нужен. Заодно это быстрый путь
            // для звонка сразу после отбоя — устройство не успело закрыться.
            retirement?.cancel()
            retirement = nil
            lastConfiguration = configuration

            let engine = current.withLock { $0 }
            engine.stop()
            ownership.withLock { $0 = AudioOwnership() }

            try engine.reconfigure(to: configuration)
            apply(handlers, to: engine)

            do {
                try engine.start()
            } catch {
                // Тракт не поднялся — владельцем никто не становится, иначе
                // линия считала бы своим звук, которого нет, и не отдала бы его
                // следующей.
                apply(Handlers(), to: engine)
                throw error
            }
            ownership.withLock { _ = $0.take(token) }
        }
    }

    /// Отпускает тракт, если он всё ещё за этим владельцем.
    ///
    /// Чужой ключ — тихий отказ, а не ошибка: сюда приходят и по отбою, и из
    /// `deinit` снятой сессии, и второй раз подряд. Единственное, чего делать
    /// нельзя, — заглушить разговор, который сейчас идёт на другой линии.
    @discardableResult
    public func release(_ token: Token) -> Bool {
        gate.sync {
            let released = ownership.withLock { $0.release(token) }
            guard released else { return false }
            let engine = current.withLock { $0 }
            engine.stop()
            apply(Handlers(), to: engine)
            scheduleRetirement()
            return true
        }
    }

    // MARK: - Арбитраж маршрута

    /// Чем кончилась заявка на гарнитуру.
    public struct ArbitrationOutcome: Sendable {
        /// Система сменила устройство по умолчанию — то есть звук действительно
        /// переехал на гарнитуру.
        public var defaultDeviceChanged = false
        /// Арбитраж недоступен: macOS 10.15. Не ошибка, просто нечем.
        public var isUnavailable = false
        public var timedOut = false
        public var error: String?

        public var summary: String {
            if isUnavailable { return "арбитраж маршрута недоступен до macOS 11" }
            if let error { return "арбитраж маршрута не удался: \(error)" }
            if timedOut { return "арбитраж маршрута не ответил вовремя" }
            return defaultDeviceChanged
                ? "устройство по умолчанию переключено системой"
                : "устройство по умолчанию оставлено прежним"
        }
    }

    /// Просит систему отдать нам ближайшую беспроводную гарнитуру.
    ///
    /// **Зачем.** Это то, чем FaceTime и другие клиенты переключают звук на
    /// AirPods в начале разговора, а у нас этого не происходило. Само по себе
    /// открытие устройства гарнитуру не забирает: если AirPods слушают iPhone,
    /// они останутся у него, а мы возьмём то, что стоит системным по умолчанию.
    /// `AVAudioRoutingArbiter` — единственный способ вмешаться: он
    /// договаривается с соседними устройствами Apple и **может сменить
    /// системное устройство по умолчанию** (`AVAudioRoutingArbiter.h`).
    ///
    /// Категория `.playAndRecordVoice` — та, что заголовок называет
    /// подходящей для VoIP.
    ///
    /// Звать надо не один раз за жизнь приложения, а перед каждым запуском
    /// ввода-вывода: пока мы молчали, гарнитуру мог забрать соседний iPhone.
    /// Так и написано в заголовке.
    ///
    /// Ожидание ограничено секундой. Заявка ходит по воздуху к соседним
    /// устройствам, и повода верить, что ответ придёт всегда, нет; а разговор
    /// начать важнее, чем дождаться идеального маршрута. Заголовок это прямо
    /// разрешает: «I/O will be started upon the app request even if
    /// beginArbitration fails».
    public func beginArbitration() async -> ArbitrationOutcome {
        guard #available(macOS 11.0, *) else {
            return ArbitrationOutcome(isUnavailable: true)
        }

        return await withCheckedContinuation { continuation in
            let answered = UnfairLock(initialState: false)
            @Sendable func finish(_ outcome: ArbitrationOutcome) {
                let isFirst = answered.withLock { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                if isFirst { continuation.resume(returning: outcome) }
            }

            gate.asyncAfter(deadline: .now() + 1) {
                finish(ArbitrationOutcome(timedOut: true))
            }

            AVAudioRoutingArbiter.shared.begin(
                category: .playAndRecordVoice
            ) { defaultDeviceChanged, error in
                finish(ArbitrationOutcome(
                    defaultDeviceChanged: defaultDeviceChanged,
                    error: error?.localizedDescription
                ))
            }
        }
    }

    /// Сообщает системе, что звук нам больше не нужен.
    ///
    /// Без этого соседний iPhone не сможет забрать гарнитуру обратно: мы
    /// останемся в очереди на неё, хотя давно положили трубку. Заголовок
    /// требует звать это по окончании разговора и не звать на короткой паузе —
    /// поэтому вызов живёт рядом с заменой движка, то есть там, где уже решено,
    /// что тракт не нужен.
    private func leaveArbitration() {
        guard #available(macOS 11.0, *) else { return }
        AVAudioRoutingArbiter.shared.leave()
    }

    /// Ставит движок на замену.
    ///
    /// **Зачем вообще менять то, ради чего всё затевалось.** Общий движок
    /// появился, чтобы `AVAudioEngine` не разбирался в момент отбоя, — и это
    /// по-прежнему так. Но замер 6 августа 2026 (`audioprobe release`, три
    /// прогона) показал, что Bluetooth-гарнитуру сегодня возвращает из режима
    /// связи **только освобождение объекта движка**: ни `engine.stop()`, ни
    /// `removeTap`+`detach`+`reset`, ни `setVoiceProcessingEnabled(false)` — ни
    /// одним вызовом, ни двумя, — ни переназначение устройства узлу
    /// (−10851). Прежняя запись в `docs/audio.md` про «отпускает именно
    /// выключение обработки голоса» устарела.
    ///
    /// Значит, отпустить AirPods без освобождения объекта нечем, и вопрос
    /// только в том, **когда** его освобождать. Не в витке отбоя, где остановка
    /// только что поставила уведомления слушателю узла ввода-вывода: ровно это
    /// и было падением. Отсюда отсрочка, своя очередь вместо главного потока и
    /// проверка, что тракт всё ещё свободен.
    ///
    /// Звонок, начатый раньше срока, замену отменяет — и это не только про
    /// скорость: пересобирать устройство, которое сейчас же понадобится снова,
    /// значит добавить оператору лишнюю паузу в начале разговора.
    private func scheduleRetirement() {
        retirement?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.retireEngine() }
        retirement = work
        gate.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Отпускает всё, что держало устройство. Вызывается на `gate`.
    private func retireEngine() {
        retirement = nil
        // Пока замена ждала своего часа, тракт могли забрать.
        guard !isBusy else { return }

        // Из очереди на гарнитуру выходим всегда: соседний iPhone имеет право
        // забрать её обратно независимо от того, держим ли мы карту открытой.
        leaveArbitration()

        // А вот выключенное «отпускать устройство» означает ровно это: движок
        // живёт дальше и держит карту. На проводной гарнитуре отпускать нечего,
        // а лишний разбор стоит паузы в начале следующего звонка.
        guard lastConfiguration?.releasesDeviceWhenIdle ?? true else { return }

        guard let replacement = try? VoiceAudioEngine(
            configuration: lastConfiguration ?? .init()
        ) else {
            // Свежий не собрался — оставляем прежний. Разговор без
            // эхоподавления плох, разговор без движка невозможен вовсе.
            return
        }

        let previous = current.withLock { engine -> VoiceAudioEngine in
            let previous = engine
            engine = replacement
            return previous
        }
        // `previous` умирает здесь, на очереди шины: `deinit` движка
        // останавливает тракт (уже остановленный — вхолостую), и разбор
        // `AVAudioEngine` уходит с главного потока. На AirPods он занимал
        // заметную часть тех 1,4 с, что отбой держал интерфейс.
        withExtendedLifetime(previous) {}
    }

    /// Даёт добраться до движка тому, кто им владеет.
    ///
    /// Возврат nil означает «звук сейчас не ваш» — для фоновой линии это
    /// обычное состояние, а не отказ.
    public func withEngine<T>(_ token: Token, _ body: (VoiceAudioEngine) -> T) -> T? {
        guard isOwner(token) else { return nil }
        // Ссылка достаётся из-под замка и отпускается до вызова: держать замок,
        // пока чужой код читает уровни, незачем. Подменить движок в этот момент
        // некому — замена бывает только на свободном тракте.
        return body(current.withLock { $0 })
    }

    /// Перезапускает тракт по требованию владельца — смена устройства в
    /// настройках, ручная пересборка.
    public func restart(_ token: Token, reason: String) {
        guard isOwner(token) else { return }
        current.withLock { $0 }.restart(reason: reason)
    }

    private func apply(_ handlers: Handlers, to engine: VoiceAudioEngine) {
        engine.onDiagnostic = handlers.diagnostic
        engine.onEvent = handlers.event
        engine.onEncodedFrame = handlers.encodedFrame
        engine.onDecodedSamples = handlers.decodedSamples
        engine.onNeedsFrame = handlers.needsFrame
    }
}
