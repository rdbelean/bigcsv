import Foundation

/// Locale-tolerant numeric parsing for filter / sort / statistics.
///
/// Tries the plain US form first (`1234.56`), then a European-normalized form
/// (`1.234,56` → strip thousands `.`, decimal `,` → `.`). This covers the two
/// common real-world CSV number styles. A bare `1.234` is read as US `1.234`
/// (genuinely ambiguous — the `,xx` decimal in European data disambiguates).
public nonisolated enum NumberParsing {

    public static func parse(_ string: String) -> Double? {
        let t = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if let d = Double(t) { return d }                 // 1234.56 / 1234 / -3.5e2
        // European: 1.234,56 → 1234.56  (and 1,5 → 1.5)
        let normalized = t.replacingOccurrences(of: ".", with: "")
                          .replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }

    /// True if a strong majority of the (non-empty) sampled values are numbers.
    public static func isNumericColumn(_ values: [String]) -> Bool {
        var checked = 0, numeric = 0
        for value in values {
            if value.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            checked += 1
            if parse(value) != nil { numeric += 1 }
            if checked >= 200 { break }
        }
        return checked > 0 && Double(numeric) / Double(checked) >= 0.8
    }
}
