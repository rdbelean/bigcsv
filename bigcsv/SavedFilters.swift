import Foundation

/// A named, reusable filter the user saved (Pro). `FilterSet` is `Codable`, so this
/// persists as JSON in `UserDefaults`. Filters are app-wide (not per-file): a saved
/// filter references columns by index, so applying it to a different file maps to
/// whatever columns sit at those positions.
struct SavedFilter: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var filterSet: FilterSet
}

enum SavedFiltersStore {
    private static let key = "com.rdb.bigcsv.savedFilters.v1"

    static func load() -> [SavedFilter] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([SavedFilter].self, from: data) else { return [] }
        return list
    }

    static func save(_ filters: [SavedFilter]) {
        guard let data = try? JSONEncoder().encode(filters) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
