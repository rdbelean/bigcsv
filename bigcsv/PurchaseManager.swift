import Foundation
import Combine
import StoreKit

/// A paid feature, used to gate UI and tailor the paywall headline.
enum Feature: String, Identifiable, CaseIterable {
    case filter, statistics, export, freezeColumns, multipleTabs, savedFilters
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .filter: return "Filtering"
        case .statistics: return "Column statistics"
        case .export: return "Export"
        case .freezeColumns: return "Freeze columns"
        case .multipleTabs: return "Multiple tabs"
        case .savedFilters: return "Saved filters"
        }
    }
}

/// Identifies which feature triggered the paywall (drives the sheet).
struct PaywallContext: Identifiable, Equatable {
    let id = UUID()
    let feature: Feature
}

/// The single source of truth for the one-time "BigCSV Pro" unlock (StoreKit 2).
///
/// `isUnlocked` is re-derived from `Transaction.currentEntitlements` on every
/// launch (never a spoofable local flag) and kept live by a lifetime
/// `Transaction.updates` listener (purchases / restores / refunds / family
/// sharing). Lives in the app target — StoreKit has no place in the nonisolated,
/// `swift test`-able core.
@MainActor
final class PurchaseManager: ObservableObject {

    static let shared = PurchaseManager()
    static let productID = "com.rdb.bigcsv.pro"

    enum PurchaseState: Equatable { case idle, loading, purchasing, restoring, failed(String) }

    @Published private(set) var isUnlocked = false
    @Published private(set) var product: Product?
    @Published private(set) var purchaseState: PurchaseState = .idle
    @Published var paywallContext: PaywallContext?

    private var updatesTask: Task<Void, Never>?

    private init() {
        updatesTask = listenForTransactions()
        Task { await loadProduct(); await refreshEntitlements() }
    }

    deinit { updatesTask?.cancel() }

    // MARK: Gate

    /// Run `action` if unlocked; otherwise present the paywall for `feature`.
    func requireUnlock(_ feature: Feature, perform action: () -> Void) {
        if isUnlocked { action() } else { presentPaywall(feature) }
    }

    func presentPaywall(_ feature: Feature) {
        paywallContext = PaywallContext(feature: feature)
    }

    // MARK: StoreKit

    func loadProduct() async {
        purchaseState = .loading
        do {
            product = try await Product.products(for: [Self.productID]).first
            purchaseState = .idle
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    func refreshEntitlements() async {
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == Self.productID,
               transaction.revocationDate == nil {
                unlocked = true
            }
        }
        isUnlocked = unlocked
    }

    func purchase() async {
        if product == nil { await loadProduct() }
        guard let product else {
            purchaseState = .failed("Couldn’t load the product. In Xcode: Edit Scheme → Run → "
                + "Options → StoreKit Configuration → select BigCSV.storekit.")
            return
        }
        purchaseState = .purchasing
        do {
            switch try await product.purchase() {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await refreshEntitlements()
                purchaseState = .idle
                if isUnlocked { paywallContext = nil }
            case .userCancelled, .pending:
                purchaseState = .idle
            @unknown default:
                purchaseState = .idle
            }
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    func restore() async {
        purchaseState = .restoring
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            purchaseState = .idle
            if isUnlocked { paywallContext = nil }
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update {
                    await transaction.finish()
                    await self?.refreshEntitlements()
                }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let safe): return safe
        case .unverified: throw PurchaseError.unverified
        }
    }

    enum PurchaseError: LocalizedError {
        case unverified
        var errorDescription: String? { "This purchase could not be verified." }
    }
}
