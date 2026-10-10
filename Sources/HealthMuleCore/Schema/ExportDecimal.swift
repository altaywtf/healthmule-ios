import Foundation

enum ExportDecimalError: Error {
    case nonFiniteDerivedValue
}

enum ExportDecimal {
    static func quantized(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        // Larger Doubles are already integers; smaller magnitudes round to zero.
        guard abs(value) < 1e16 else { return value }
        guard abs(value) >= 0.005 else { return 0 }
        // The shortest decimal representation defines the midpoint, not binary noise.
        guard var decimal = Decimal(
            string: String(value),
            locale: Locale(identifier: "en_US_POSIX")
        ) else {
            preconditionFailure("A finite measurement in the decimal range must parse.")
        }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &decimal, 2, .plain)
        guard let result = Double(NSDecimalNumber(decimal: rounded).stringValue) else {
            preconditionFailure("A rounded finite decimal must parse as a Double.")
        }
        return normalizedZero(result)
    }

    static func quantized(_ value: Double?) -> Double? {
        value.map(quantized)
    }

    static func quantizedSum(_ values: [Double]) throws -> Double {
        quantized(try sum(values))
    }

    static func sum(_ values: [Double]) throws -> Double {
        var sum = 0.0
        var compensation = 0.0
        for value in values {
            guard value.isFinite else {
                throw ExportDecimalError.nonFiniteDerivedValue
            }
            let adjusted = value - compensation
            let next = sum + adjusted
            guard adjusted.isFinite, next.isFinite else {
                throw ExportDecimalError.nonFiniteDerivedValue
            }
            compensation = (next - sum) - adjusted
            guard compensation.isFinite else {
                throw ExportDecimalError.nonFiniteDerivedValue
            }
            sum = next
        }
        return sum
    }

    private static func normalizedZero(_ value: Double) -> Double {
        value == 0 ? 0 : value
    }
}
