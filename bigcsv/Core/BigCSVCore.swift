import Foundation

/// Namespace + version marker for the BigCSV core logic.
///
/// The core lives in `bigcsv/Core/` and is compiled both into the app target
/// (SwiftUI/AppKit shell) and into the `BigCSVKit` Swift package (for tests).
/// Everything in this folder must be pure Foundation/Darwin and declare its
/// concurrency isolation explicitly so it behaves identically in both contexts.
public nonisolated enum BigCSVCore {
    /// Current core version, surfaced in About / diagnostics.
    public static let version = "0.1.0"
}
