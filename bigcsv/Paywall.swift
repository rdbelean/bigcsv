import SwiftUI
import StoreKit

/// The unlock sheet, presented when a locked feature is tapped.
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

            if case .failed(let message) = purchase.purchaseState {
                Text(message).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }

            Button { Task { await purchase.purchase() } } label: {
                Text(buyTitle).frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(isBusy)

            Button("Restore Purchases") { Task { await purchase.restore() } }
                .disabled(isBusy)
            Button("Not now") { dismiss() }
                .buttonStyle(.link)
        }
        .padding(28)
        .frame(width: 430)
    }

    private var isBusy: Bool {
        purchase.purchaseState == .purchasing || purchase.purchaseState == .restoring
    }

    private var buyTitle: String {
        switch purchase.purchaseState {
        case .purchasing: return "Purchasing…"
        case .restoring: return "Restoring…"
        default:
            if let product = purchase.product { return "Unlock Pro — \(product.displayPrice)" }
            return "Unlock Pro"
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
