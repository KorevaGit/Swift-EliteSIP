import Foundation

/// Отказы административного доступа.
///
/// Все они показываются человеку, поэтому у каждого есть текст на русском —
/// и текст этот намеренно не уточняет, что именно не сошлось: «пароль неверен»
/// и «код неверен» не должны различаться подробностью сообщения.
public enum AdminAccessError: Error, LocalizedError, Equatable, Sendable {

    /// Пароль не подошёл.
    case wrongPassword

    /// Пароль пуст. Пустой пароль — это отсутствие пароля, а не пароль.
    case emptyPassword

    /// Учётные данные в файле настроек испорчены: обрезаны, переписаны руками
    /// или сохранены сборкой, которая писала их иначе.
    case malformedCredential

    /// CommonCrypto отказался считать. Практически недостижимо; существует,
    /// чтобы не превращать отказ в молчаливый нулевой ключ.
    case derivationFailed

    /// Строки берутся из каталога самого пакета (`Bundle.module`), а не из
    /// приложения: иначе перевод отказа пришлось бы держать там, где об этих
    /// отказах ничего не известно.
    public var errorDescription: String? {
        switch self {
        case .wrongPassword:
            NSLocalizedString("Неверный пароль.", bundle: .module, comment: "отказ доступа")
        case .emptyPassword:
            NSLocalizedString("Пароль не может быть пустым.", bundle: .module, comment: "отказ доступа")
        case .malformedCredential:
            NSLocalizedString(
                "Данные административного доступа испорчены. Задайте пароль заново.",
                bundle: .module,
                comment: "отказ доступа"
            )
        case .derivationFailed:
            NSLocalizedString("Не удалось проверить пароль.", bundle: .module, comment: "отказ доступа")
        }
    }
}
