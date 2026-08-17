import CommonCrypto
import Foundation

/// PBKDF2-HMAC-SHA256 — единственный способ, которым пароль и код
/// восстановления превращаются в байты.
///
/// Не голый SHA-256: пароль администратора человек придумывает сам, и по
/// одному быстрому хешу словарь из миллиона вариантов перебирается за секунды.
/// PBKDF2 умножает цену перебора на число итераций, и это единственное, что в
/// принципе можно противопоставить короткому паролю.
///
/// CommonCrypto, а не `HKDF` из CryptoKit: `HKDF` появился в macOS 11, а срез
/// x86_64 живёт с Catalina. И HKDF решает другую задачу — растянуть уже
/// случайный ключ, а не удорожить перебор.
enum KeyDerivation {

    /// Итераций по умолчанию.
    ///
    /// Число подобрано под самую слабую целевую машину, а не под эту: на
    /// Core i5 2013 года это доли секунды, и платятся они один раз за нажатие
    /// «Войти». Значение хранится в самих учётных данных, поэтому его можно
    /// поднять, не ломая уже настроенные рабочие места.
    static let defaultIterations = 150_000

    /// Потолок числа итераций, принимаемого из файла.
    ///
    /// Число приезжает снаружи: из настроек, которые правит человек, и из файла
    /// конфигурации, который человек же может собрать сам. `iterations:
    /// 2000000000` — это не стойкость, а зависший процесс: PBKDF2 честно
    /// отработает столько, сколько попросили, и произойдёт это на нажатии
    /// «Войти», то есть будет выглядеть как зависшее приложение, а не как
    /// испорченный файл.
    ///
    /// Миллион — на Core i5 2013 года это единицы секунд: предел терпения, а не
    /// предел работы.
    static let maximumIterations = 1_000_000

    /// Нижней границы намеренно нет.
    ///
    /// Она выглядела бы уместной — «тысяча итераций это слабо», — но не даёт
    /// ничего. Своё мы пишем только с `defaultIterations`; маленькое число
    /// может появиться лишь от правки файла руками, а тот, кто правит файл,
    /// с тем же успехом перепишет учётные данные целиком, своим паролем и
    /// своей солью. Пол защищал бы от противника, которому он не мешает, и
    /// ломал бы проверки, которым дорогой перебор не нужен.
    ///
    /// Что происходит с подделанным сверху: проверка не сходится, и человек
    /// видит «неверный пароль». Это и есть цель — превратить зависание в отказ.
    static func boundedIterations(_ value: Int) -> Int {
        min(value, maximumIterations)
    }

    /// Байты, выведенные из строки и соли.
    ///
    /// Пустая соль отвергается: без неё одинаковые пароли на разных машинах
    /// дают одинаковый хеш, и радужная таблица снова становится осмысленной.
    static func derive(
        from secret: String,
        salt: Data,
        iterations: Int,
        byteCount: Int = 32
    ) throws -> Data {
        guard !salt.isEmpty, iterations > 0, byteCount > 0 else {
            throw AdminAccessError.malformedCredential
        }

        let secretBytes = Array(secret.utf8)
        var derived = Data(count: byteCount)

        let status: Int32 = derived.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBuffer in
                secretBytes.withUnsafeBufferPointer { secretBuffer in
                    // Пустая строка даёт нулевой baseAddress, а CommonCrypto
                    // ждёт указатель. Пустой пароль всё равно не проходит
                    // проверку выше по стеку, но падать здесь ему незачем.
                    let secretPointer = secretBuffer.baseAddress.map {
                        UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self)
                    }
                    return CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        secretPointer,
                        secretBytes.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        output.bindMemory(to: UInt8.self).baseAddress,
                        byteCount
                    )
                }
            }
        }

        guard status == kCCSuccess else { throw AdminAccessError.derivationFailed }
        return derived
    }

    /// Случайная соль.
    static func randomSalt(byteCount: Int = 16) -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        // Отказ системного генератора — не тот случай, который можно обойти
        // своим: пусть лучше соль будет из `SystemRandomNumberGenerator`,
        // который тоже берёт энтропию у ядра, чем предсказуемой.
        if status != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return Data(bytes)
    }

    /// Сравнение за постоянное время.
    ///
    /// `==` у `Data` выходит на первом несовпавшем байте, и по времени ответа
    /// хеш подбирается побайтово. Здесь это скорее гигиена, чем защита от
    /// реальной атаки — мерить время локального диалога некому, — но правило
    /// «секреты сравниваются так» дешевле соблюдать всегда, чем вспоминать,
    /// где оно действительно нужно.
    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}
