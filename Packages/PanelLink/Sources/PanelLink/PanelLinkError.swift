import Foundation

/// Отказы при разборе того, что пришло от панели.
///
/// Список короткий намеренно. Он не описывает, что именно пошло не так внутри
/// криптографии, — он описывает то, что человеку осмысленно показать.
public enum PanelLinkError: Error, Equatable, LocalizedError {

    /// Конфигурация машины не расшифровалась её ключом.
    ///
    /// Чужой ключ и испорченный файл неотличимы по ответу, и это решение: тот,
    /// кто подсовывает файлы, не должен узнавать, что именно не сошлось.
    case configDidNotOpen

    /// Конфигурация собрана более новой версией Spark.
    case configTooNew

    /// Файл предустановок не прошёл проверку подписи.
    case signatureDidNotMatch

    /// Файл предустановок собран более новой версией.
    case bundleTooNew

    /// Файл предустановок не разобрался.
    case malformedBundle

    public var errorDescription: String? {
        switch self {
        case .configDidNotOpen:
            return NSLocalizedString(
                "Настройки машины не расшифровались — попросите привязать её заново.",
                bundle: .module,
                comment: "отказ при расшифровке конфигурации машины"
            )
        case .configTooNew:
            return NSLocalizedString(
                "Настройки собраны более новой версией — обновите приложение.",
                bundle: .module,
                comment: "отказ при разборе конфигурации машины"
            )
        case .signatureDidNotMatch:
            return NSLocalizedString(
                "Подпись файла настроек не сошлась — файл отброшен.",
                bundle: .module,
                comment: "отказ при проверке файла предустановок"
            )
        case .bundleTooNew:
            return NSLocalizedString(
                "Файл настроек собран более новой версией программы.",
                bundle: .module,
                comment: "отказ при проверке файла предустановок"
            )
        case .malformedBundle:
            return NSLocalizedString(
                "Файл настроек не разобрался.",
                bundle: .module,
                comment: "отказ при проверке файла предустановок"
            )
        }
    }
}
