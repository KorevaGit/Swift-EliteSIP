import Foundation

/// Подпись раздачи по имени, с которым она пришла в `From`.
///
/// Название линии едет в имени звонящего — номер очереди в вызов не попадает
/// вовсе, поэтому прежний словарь «номер → название» не сработал ни разу.
/// Правила «что искать в имени → как показать» заводятся в Spark (вкладка
/// «Очереди») и приезжают в файле предустановок (`PresetBundle.queues`). Имя
/// без правила показывается как пришло, только слипшиеся слова разделяются:
/// перевод с транслита угадывал бы, а ошибка в заголовке окна путает сильнее
/// латиницы.
///
/// То же правило в Spark (`frontend/src/lib/queueTitles.js`,
/// `preset/queues.go`) и в Windows- и Linux-версиях: предпросмотр там обязан
/// показывать то, что увидит оператор. Примеры в проверках общие.
public enum QueueTitles {

    /// Правило, готовое к сверке: ключ посчитан один раз.
    public struct Rule: Sendable, Equatable {
        public let key: String
        public let title: String
    }

    /// Правила из пар «искать → показать»; строки без искомого или без
    /// подписи не работают.
    public static func rules<S: Sequence>(_ titles: S) -> [Rule] where S.Element == PresetBundle.QueueTitle {
        titles
            .map { Rule(key: key($0.match), title: $0.title.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.key.isEmpty && !$0.title.isEmpty }
    }

    /// По чему правило сверяется с именем: без регистра, пробелов и подчёркиваний.
    public static func key(_ text: String?) -> String {
        guard let text else { return "" }
        return String(text.unicodeScalars
            .filter { $0 != "_" && !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(Character.init)).lowercased()
    }

    /// Имя в читаемом виде: подчёркивания — пробелы, слипшиеся слова разделены
    /// по смене регистра и на границе букв и цифр. Ничего не переводит.
    public static func tidy(_ name: String?) -> String {
        guard var text = name?.replacingOccurrences(of: "_", with: " "),
              !text.trimmingCharacters(in: .whitespaces).isEmpty
        else { return "" }

        for pattern in [#"(\p{Ll})(\p{Lu})"#, #"(\p{Lu})(\p{Lu}\p{Ll})"#,
                        #"(\p{L})(\p{Nd})"#, #"(\p{Nd})(\p{L})"#] {
            text = text.replacingOccurrences(of: pattern, with: "$1 $2", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// Заголовок раздачи с таким именем: подпись первого подходящего правила,
    /// иначе причёсанное имя. `nil` — имени нет, сказать нечего.
    ///
    /// Имя без единой буквы именем не считается: так транк повторяет в нём
    /// номер, и заголовком встал бы мобильный лида.
    public static func headline(_ name: String?, rules: [Rule]) -> String? {
        guard let name, name.contains(where: \.isLetter) else { return nil }
        let wanted = key(name)
        return rules.first { wanted.contains($0.key) }?.title ?? tidy(name)
    }
}
