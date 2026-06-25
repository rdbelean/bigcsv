import Testing
@testable import BigCSVKit

/// Phase 0 smoke test: proves the package builds and `swift test` runs.
@Test
func coreVersionIsSet() {
    #expect(BigCSVCore.version == "0.1.0")
}
