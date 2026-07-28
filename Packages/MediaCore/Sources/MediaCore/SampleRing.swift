import Foundation

/// Кольцо готовых к воспроизведению отсчётов между сетью и звуковой картой.
///
/// Вынесено из движка отдельным типом ради двух вещей. Первая — его можно
/// проверить тестами без звуковой карты, а именно здесь живёт вся арифметика,
/// от которой зависит, будет ли слышен щелчок. Вторая — из потока рендера
/// нельзя ни выделять память, ни брать блокировку надолго, поэтому буфер
/// заведомо фиксированного размера, и это свойство должно быть видно в типе, а
/// не спрятано в комментарии.
struct SampleRing {

    private var storage: [Float]
    private var readIndex = 0
    private var count = 0

    /// Сколько отсчётов держать наготове. Меньше — риск недобора на любой
    /// неровности, больше — лишняя задержка сверх джиттер-буфера.
    let targetFill: Int

    init(capacity: Int, targetFill: Int) {
        precondition(capacity > 0, "кольцо нулевого размера бессмысленно")
        precondition(targetFill <= capacity, "цель заполнения не может превышать ёмкость")
        storage = [Float](repeating: 0, count: capacity)
        self.targetFill = targetFill
    }

    var capacity: Int { storage.count }
    var available: Int { count }
    var freeSpace: Int { storage.count - count }

    /// Сколько отсчётов не хватает до целевого запаса.
    var deficit: Int { max(0, targetFill - count) }

    // MARK: - Запись

    /// Добавляет отсчёты. Возвращает, сколько поместилось.
    ///
    /// Не поместившееся отбрасывается молча: вызывающий и так спрашивает
    /// `freeSpace` перед тем, как декодировать кадр, а бросать из звукового
    /// тракта нечем и некому.
    @discardableResult
    mutating func write(_ samples: [Float]) -> Int {
        samples.withUnsafeBufferPointer { buffer in
            write(buffer.baseAddress!, count: buffer.count)
        }
    }

    /// То же самое из сырого указателя.
    ///
    /// Нужно на стороне захвата: блок `AVAudioSinkNode` вызывается на потоке
    /// реального времени и получает буферы CoreAudio напрямую. Заворачивать их
    /// в массив ради красоты значило бы выделять память там, где выделять
    /// нельзя.
    @discardableResult
    mutating func write(_ samples: UnsafePointer<Float>, count sampleCount: Int) -> Int {
        let writable = min(sampleCount, freeSpace)
        guard writable > 0 else { return 0 }

        let writeIndex = (readIndex + count) % storage.count
        let firstChunk = min(writable, storage.count - writeIndex)
        storage.withUnsafeMutableBufferPointer { destination in
            destination.baseAddress!.advanced(by: writeIndex)
                .update(from: samples, count: firstChunk)
            if writable > firstChunk {
                destination.baseAddress!
                    .update(from: samples.advanced(by: firstChunk), count: writable - firstChunk)
            }
        }
        count += writable
        return writable
    }

    // MARK: - Чтение

    /// Выкладывает `requested` отсчётов в буфер вывода, добивая тишиной.
    ///
    /// Отдать меньше, чем попросили, нельзя: движок воспримет это как обрыв.
    /// Возвращает, сколько из них были настоящим звуком — по разнице и
    /// считаются недоборы.
    @discardableResult
    mutating func read(into destination: UnsafeMutablePointer<Float>, requested: Int) -> Int {
        let readable = min(requested, count)

        for offset in 0..<readable {
            destination[offset] = storage[(readIndex + offset) % storage.count]
        }
        for offset in readable..<requested {
            destination[offset] = 0
        }

        readIndex = (readIndex + readable) % storage.count
        count -= readable
        return readable
    }

    /// Забирает всё, что накопилось, но не больше `maximum`.
    ///
    /// Для стороны захвата: там читает обычный поток, а не рендер, и массив ему
    /// удобнее указателя. Ограничение сверху есть затем, чтобы опоздавший поток
    /// не выгреб полсекунды разом и не отправил их в сеть пачкой.
    mutating func drain(maximum: Int) -> [Float] {
        let readable = min(maximum, count)
        guard readable > 0 else { return [] }

        var result = [Float](repeating: 0, count: readable)
        result.withUnsafeMutableBufferPointer { destination in
            _ = read(into: destination.baseAddress!, requested: readable)
        }
        return result
    }

    mutating func removeAll() {
        readIndex = 0
        count = 0
    }
}
