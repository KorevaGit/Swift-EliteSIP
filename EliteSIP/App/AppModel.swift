import Observation
import SwiftUI

/// Состояние приложения.
///
/// На M0 здесь только форма: сигнализации ещё нет, поэтому ничего, кроме ввода
/// номера и показа окна входящего, работать не может — и не притворяется, что
/// может. Регистрация приезжает в M1, звонок в M2.
@MainActor
@Observable
final class AppModel {

    enum RegistrationState: Equatable {
        case offline
        case registering
        case registered
        case failed(reason: String)

        var title: String {
            switch self {
            case .offline: "Не подключено"
            case .registering: "Регистрация…"
            case .registered: "На линии"
            case .failed(let reason): "Ошибка: \(reason)"
            }
        }
    }

    /// Черновик учётной записи.
    ///
    /// Пароля здесь намеренно нет. Он появится в M1 вместе с регистрацией и
    /// сразу поедет в Keychain — держать его в обычном свойстве модели, пусть
    /// и в памяти, незачем.
    struct Account {
        var username: String = ""
        var displayName: String = ""
        var domain: String = ""
        var port: UInt16 = 5061
        var transport: String = "tls"
    }

    /// Настройки рандомизации окна входящего вызова.
    struct IncomingCallPlacementSettings {
        /// Минимальное смещение от прошлой позиции, чтобы окно не появлялось
        /// дважды в одном месте и оператор не жал по мышечной памяти.
        var minimumTravel: CGFloat = 150
        /// Отступ от краёв рабочей области.
        var screenMargin: CGFloat = 24
        var isEnabled: Bool = true
    }

    var registration: RegistrationState = .offline
    var dialedNumber: String = ""
    var account = Account()
    var placement = IncomingCallPlacementSettings()

    /// Позвонить пока физически некуда: транспорт и медиа появляются в M1–M2.
    var canPlaceCall: Bool { false }

    var hasDialedNumber: Bool { !dialedNumber.isEmpty }

    func append(_ digit: Character) {
        // Ограничение по длине защищает вёрстку от бесконечной строки.
        guard dialedNumber.count < 32 else { return }
        dialedNumber.append(digit)
    }

    func removeLastDigit() {
        guard !dialedNumber.isEmpty else { return }
        dialedNumber.removeLast()
    }

    func clearDialedNumber() {
        dialedNumber.removeAll()
    }
}
