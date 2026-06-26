import Foundation

/// A comparison operator for one column condition.
public nonisolated enum FilterOperator: String, Codable, Sendable, CaseIterable, Equatable {
    case contains, doesNotContain, equals, notEquals, beginsWith, endsWith
    case greaterThan, lessThan          // numeric
    case isEmpty, isNotEmpty

    public var displayName: String {
        switch self {
        case .contains: return "contains"
        case .doesNotContain: return "does not contain"
        case .equals: return "equals"
        case .notEquals: return "not equals"
        case .beginsWith: return "begins with"
        case .endsWith: return "ends with"
        case .greaterThan: return "greater than"
        case .lessThan: return "less than"
        case .isEmpty: return "is empty"
        case .isNotEmpty: return "is not empty"
        }
    }

    /// Operators that don't need a comparison value.
    public var needsValue: Bool { self != .isEmpty && self != .isNotEmpty }
}

/// One column condition: "column <op> value".
public nonisolated struct ColumnCondition: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var column: Int
    public var op: FilterOperator
    public var value: String
    public var caseSensitive: Bool

    public init(id: UUID = UUID(), column: Int, op: FilterOperator = .contains,
                value: String = "", caseSensitive: Bool = false) {
        self.id = id
        self.column = column
        self.op = op
        self.value = value
        self.caseSensitive = caseSensitive
    }

    /// Evaluate against a parsed row. Out-of-range columns read as empty (ragged
    /// rows never trap). Numeric ops treat empty / non-numeric as NON-matching.
    public func matches(_ fields: [String]) -> Bool {
        let cell = (column >= 0 && column < fields.count) ? fields[column] : ""
        switch op {
        case .isEmpty:
            return cell.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .isNotEmpty:
            return !cell.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .greaterThan, .lessThan:
            guard let a = NumberParsing.parse(cell), let b = NumberParsing.parse(value) else { return false }
            return op == .greaterThan ? a > b : a < b
        case .contains, .doesNotContain, .equals, .notEquals, .beginsWith, .endsWith:
            let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            switch op {
            case .contains: return cell.range(of: value, options: options) != nil
            case .doesNotContain: return cell.range(of: value, options: options) == nil
            case .equals: return cell.compare(value, options: options) == .orderedSame
            case .notEquals: return cell.compare(value, options: options) != .orderedSame
            case .beginsWith: return cell.range(of: value, options: options.union(.anchored)) != nil
            case .endsWith: return cell.range(of: value, options: options.union([.anchored, .backwards])) != nil
            default: return false
            }
        }
    }
}

/// A set of conditions combined with AND (all) or OR (any).
public nonisolated struct FilterSet: Codable, Sendable, Equatable {
    public enum Combinator: String, Codable, Sendable { case all, any }

    public var combinator: Combinator
    public var conditions: [ColumnCondition]

    public init(combinator: Combinator = .all, conditions: [ColumnCondition] = []) {
        self.combinator = combinator
        self.conditions = conditions
    }

    public var isEmpty: Bool { conditions.isEmpty }

    public func matches(_ fields: [String]) -> Bool {
        guard !conditions.isEmpty else { return true }
        switch combinator {
        case .all: return conditions.allSatisfy { $0.matches(fields) }
        case .any: return conditions.contains { $0.matches(fields) }
        }
    }
}
