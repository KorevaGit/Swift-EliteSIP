import Foundation

/// Кусок JSON, сохранённый как есть.
///
/// Нужен ровно для одного: управляемые поля предустановки не разбираются на
/// этом уровне. Разбирает их приложение — тем же путём, каким разбирает файл
/// предустановок, — а пакет и файл только доносят их в целости.
///
/// Своими руками, а не `JSONSerialization` по всему телу: разбирать документ
/// дважды означало бы, что строгий разбор верхнего уровня и терпимый разбор
/// полей могут разойтись во мнении о том, что вообще было в файле.
struct AnyJSON: Decodable {

    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyJSON].self) {
            value = array.map(\.value)
        } else if let object = try? container.decode([String: AnyJSON].self) {
            value = object.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "непонятное значение JSON"
            )
        }
    }
}
