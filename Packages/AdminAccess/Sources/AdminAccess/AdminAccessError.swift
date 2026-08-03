import Foundation

/// Отказы административного доступа.
///
/// Все они показываются человеку, поэтому у каждого есть текст на русском —
/// и текст этот намеренно не уточняет, что именно не сошлось: «пароль неверен»
/// и «код неверен» не должны различаться подробностью сообщения.
public enum AdminAccessError: Error, LocalizedError, Equatable, Sendable {

    /// Пароль не подошёл.
    case wrongPassword

    /// Код восстановления не подошёл.
    case wrongRecoveryCode

    /// Пароль пуст. Пустой пароль — это отсутствие пароля, а не пароль.
    case emptyPassword

    /// Код восстановления не той длины или содержит не цифры.
    case malformedRecoveryCode

    /// Учётные данные в файле настроек испорчены: обрезаны, переписаны руками
    /// или сохранены сборкой, которая писала их иначе.
    case malformedCredential

    /// CommonCrypto отказался считать. Практически недостижимо; существует,
    /// чтобы не превращать отказ в молчаливый нулевой ключ.
    case derivationFailed

    public var errorDescription: String? {
        switch self {
        case .wrongPassword:
            "Неверный пароль."
        case .wrongRecoveryCode:
            "Неверный код восстановления."
        case .emptyPassword:
            "Пароль не может быть пустым."
        case .malformedRecoveryCode:
            "Код восстановления — это \(RecoveryCode.length) цифр."
        case .malformedCredential:
            "Данные административного доступа испорчены. Задайте пароль заново."
        case .derivationFailed:
            "Не удалось проверить пароль."
        }
    }
}
