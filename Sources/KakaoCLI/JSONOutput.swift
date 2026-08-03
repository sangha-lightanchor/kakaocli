import Foundation

enum JSONOutput {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func print<T: Encodable>(_ value: T) throws {
        let data = try encoder.encode(value)
        Swift.print(String(decoding: data, as: UTF8.self))
    }
}
