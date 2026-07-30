import AudioObjCTrap
import Foundation

/// Мост к ловушке исключений Objective-C.
///
/// Нужен из-за `AVAudioEngine`: подключение узла с форматом, который не совпал
/// с текущим форматом железа, он сообщает исключением Objective-C, а не
/// ошибкой. Swift исключения Objective-C не ловит, поэтому такое несовпадение
/// кладёт процесс целиком.
///
/// Гонка настоящая и воспроизводимая: между чтением формата и подключением
/// узла проходят доли миллисекунды, но при смене звукового устройства железо
/// меняется именно в этот момент. На практике это выглядит так — оператор
/// вынимает наушники посреди разговора, и софтфон падает.
///
/// Пойманное исключение превращается в обычную ошибку, из-за которой тракт
/// пересобирается заново. Пересборка — штатный путь, он и так вызывается на
/// каждую смену конфигурации звука.
public enum AudioObjCException {

    public struct Failure: Error, LocalizedError {
        public let step: String
        public let reason: String

        public var errorDescription: String? {
            "Звуковой движок отказал на шаге «\(step)»: \(reason)"
        }
    }

    /// Выполняет замыкание, превращая исключение Objective-C в ошибку Swift.
    ///
    /// Шаг указывается всегда: сообщение вида «Input HW format and tap format
    /// not matching» не говорит, какой именно узел не сошёлся, а узлов в графе
    /// несколько.
    public static func trap(step: String, _ body: () -> Void) throws {
        var error: NSError?
        guard EliteSIPRunCatchingObjCException(body, &error) else {
            throw Failure(step: step, reason: error?.localizedDescription ?? "неизвестно")
        }
    }
}
