/// Набор заголовков сообщения.
///
/// Порядок сохраняется: RFC 3261 разрешает произвольный порядок разных
/// заголовков, но требует сохранять относительный порядок одноимённых (стек Via
/// — это буквально порядок), а ещё сохранённый порядок сильно упрощает сравнение
/// с дампом из Wireshark при отладке.
public struct SIPHeaders: Sendable, Hashable {

    public struct Field: Sendable, Hashable {
        /// Каноническое имя, уже развёрнутое из компактной формы.
        public let name: String
        public var value: String

        public init(name: some StringProtocol, value: some StringProtocol) {
            self.name = SIPHeaderName.canonical(name)
            self.value = String(value)
        }
    }

    public private(set) var fields: [Field]

    public init() {
        fields = []
    }

    public init(_ fields: [Field]) {
        self.fields = fields
    }

    public var isEmpty: Bool { fields.isEmpty }

    // MARK: - Чтение

    /// Первое значение заголовка целиком, как оно пришло.
    public func first(_ name: String) -> String? {
        let canonical = SIPHeaderName.canonical(name)
        return fields.first { $0.name == canonical }?.value
    }

    public subscript(_ name: String) -> String? {
        get { first(name) }
        set {
            if let newValue {
                set(name, to: newValue)
            } else {
                remove(name)
            }
        }
    }

    /// Все значения заголовка.
    ///
    /// Для заголовков из белого списка (`Via`, `Route`, `Contact`, …) значения,
    /// перечисленные через запятую в одной строке, разворачиваются в отдельные
    /// элементы. Для остальных — нет, иначе `WWW-Authenticate` с его
    /// `realm="a", nonce="b"` развалился бы на куски.
    public func values(_ name: String) -> [String] {
        let canonical = SIPHeaderName.canonical(name)
        let raw = fields.filter { $0.name == canonical }.map(\.value)

        guard SIPHeaderName.allowsCommaSeparatedValues(canonical) else { return raw }

        return raw.flatMap { value in
            SIPLexer.splitTopLevel(Substring(value), separator: ",")
                .map { String($0.trimmedSIP) }
                .filter { !$0.isEmpty }
        }
    }

    public func contains(_ name: String) -> Bool {
        let canonical = SIPHeaderName.canonical(name)
        return fields.contains { $0.name == canonical }
    }

    public func integer(_ name: String) -> Int? {
        first(name).flatMap { Int($0.trimmedSIP) }
    }

    // MARK: - Изменение

    /// Добавляет значение, не затрагивая существующие одноимённые.
    public mutating func append(_ name: String, _ value: some StringProtocol) {
        fields.append(Field(name: name, value: value))
    }

    /// Добавляет значение первым. Нужно для Via: свой Via всегда сверху стека.
    public mutating func prepend(_ name: String, _ value: some StringProtocol) {
        fields.insert(Field(name: name, value: value), at: 0)
    }

    /// Заменяет все значения заголовка одним.
    public mutating func set(_ name: String, to value: some StringProtocol) {
        let canonical = SIPHeaderName.canonical(name)
        guard let index = fields.firstIndex(where: { $0.name == canonical }) else {
            append(canonical, value)
            return
        }
        fields[index].value = String(value)

        // Остальные одноимённые убираем: set задаёт единственное значение и
        // должен быть идемпотентным, иначе повторный вызов размножит заголовок.
        var keptFirst = false
        fields = fields.filter { field in
            guard field.name == canonical else { return true }
            defer { keptFirst = true }
            return !keptFirst
        }
    }

    public mutating func remove(_ name: String) {
        let canonical = SIPHeaderName.canonical(name)
        fields.removeAll { $0.name == canonical }
    }

    // MARK: - Сериализация

    public var encoded: String {
        fields.map { "\($0.name): \($0.value)\r\n" }.joined()
    }
}
