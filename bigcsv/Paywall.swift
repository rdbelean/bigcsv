import SwiftUI
import StoreKit

/// The unlock sheet, presented when a locked feature is tapped.
///
/// Uses StoreKit's SwiftUI `ProductView` for the actual purchase — calling
/// `product.purchase()` directly from inside a SwiftUI sheet fails on macOS
/// ("Adding NSRemoteView as a subview of NSHostingView is not supported");
/// `ProductView` presents the system purchase UI correctly. The resulting
/// transaction flows through `PurchaseManager`'s `Transaction.updates` listener,
/// which flips `isUnlocked` and dismisses this sheet.
struct PaywallView: View {
    @ObservedObject var purchase: PurchaseManager
    let feature: Feature
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.open")
                .font(.system(size: 42, weight: .thin))
                .foregroundStyle(.tint)

            Text("\(feature.displayName) is a BigCSV Pro feature")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Unlock every Pro feature with one purchase — no subscription, ever.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 7) {
                proRow("line.3.horizontal.decrease.circle", "Filter by multiple columns")
                proRow("function", "Column statistics")
                proRow("square.and.arrow.up", "Export to CSV, JSON, Excel")
                proRow("pin", "Freeze columns + jump")
                proRow("rectangle.stack", "Multiple tabs / files")
                proRow("bookmark", "Saved filters")
            }
            .padding(.vertical, 4)

            ProductView(id: PurchaseManager.productID) {
                Image(systemName: "tablecells")
                    .font(.title)
                    .foregroundStyle(.tint)
            }
            .productViewStyle(.compact)
            .onInAppPurchaseCompletion { _, result in
                if case .success(.success) = result {
                    await purchase.refreshEntitlements()
                }
            }

            Button("Restore Purchases") { Task { await purchase.restore() } }
            Button("Not now") { dismiss() }
                .buttonStyle(.link)
        }
        .padding(28)
        .frame(width: 430)
        .onChange(of: purchase.isUnlocked) { _, unlocked in
            if unlocked { dismiss() }
        }
    }

    private func proRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.tint).frame(width: 22)
            Text(text)
            Spacer()
        }
    }
}
