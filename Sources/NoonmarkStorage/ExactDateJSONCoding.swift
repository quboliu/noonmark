import Foundation

enum ExactDateJSONCoding {
    static func encoder(nonFiniteDateDescription: String) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let seconds = date.timeIntervalSinceReferenceDate
            guard seconds.isFinite else {
                throw EncodingError.invalidValue(
                    date,
                    .init(
                        codingPath: encoder.codingPath,
                        debugDescription: nonFiniteDateDescription
                    )
                )
            }
            var container = encoder.singleValueContainer()
            try container.encode(seconds.bitPattern)
        }
        return encoder
    }

    static func decoder(nonFiniteDateDescription: String) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let seconds = Double(bitPattern: try container.decode(UInt64.self))
            guard seconds.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: nonFiniteDateDescription
                )
            }
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        return decoder
    }
}
