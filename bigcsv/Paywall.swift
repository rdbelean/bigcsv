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

/// First-launch welcome — brand-styled. Shows what Pro adds over the free app and
/// offers a one-time purchase straight through Apple (`ProductView`). Fully
/// dismissible ("Maybe later" / ✕); never shown in the free direct build, to an
/// already-unlocked user, or more than once.
struct WelcomeSheet: View {
    @ObservedObject var purchase: PurchaseManager
    @Environment(\.dismiss) private var dismiss

    private let proFeatures: [(String, String)] = [
        ("line.3.horizontal.decrease", "Filter by multiple columns"),
        ("square.and.arrow.up", "Export to CSV, TSV, JSON & Excel"),
        ("chart.bar", "Column statistics — sum, mean, min, max, median"),
        ("pin", "Freeze columns + jump to any column"),
        ("rectangle.stack", "Open multiple files in tabs"),
        ("bookmark", "Save and reuse filters"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to BigCSV")
                        .font(Brand.sansFont(22, .semibold))
                        .foregroundStyle(Color(Brand.textPrimary))
                    Text("Open giant CSVs instantly — free, forever. Unlock Pro for the power tools.")
                        .font(Brand.sansFont(13.5))
                        .foregroundStyle(Color(Brand.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(action: dismiss.callAsFunction) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(Brand.textMuted))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("Maybe later")
            }

            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Color(Brand.accentDeep))
                Text("The free app has no row limits and no nags — open, scroll, search, and sort any file.")
                    .font(Brand.sansFont(12.5)).foregroundStyle(Color(Brand.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 16)

            Text("BIGCSV PRO")
                .font(Brand.monoFont(10.5, .semibold)).tracking(1)
                .foregroundStyle(Color(Brand.accentText))
                .padding(.top, 20)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(proFeatures, id: \.1) { proRow($0.1) }
            }
            .padding(.top, 9)

            ProductView(id: PurchaseManager.productID) {
                Image(systemName: "tablecells").font(.title).foregroundStyle(Color(Brand.accentDeep))
            }
            .productViewStyle(.compact)
            .onInAppPurchaseCompletion { _, result in
                if case .success(.success) = result { await purchase.refreshEntitlements() }
            }
            .padding(.top, 18)

            HStack {
                Button("Restore Purchases") { Task { await purchase.restore() } }
                    .buttonStyle(.link).font(Brand.sansFont(12.5))
                Spacer()
                Button("Maybe later", action: dismiss.callAsFunction)
                    .buttonStyle(.plain)
                    .font(Brand.sansFont(13, .medium))
                    .foregroundStyle(Color(Brand.textSecondary))
            }
            .padding(.top, 14)
        }
        .padding(26)
        .frame(width: 440)
        .background(Color(Brand.windowBg))
        .onChange(of: purchase.isUnlocked) { _, unlocked in if unlocked { dismiss() } }
    }

    private func proRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(Brand.accentDeep))
                .frame(width: 18, height: 18)
                .background(Color(Brand.accent).opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
            Text(text).font(Brand.sansFont(13)).foregroundStyle(Color(Brand.textPrimary))
            Spacer(minLength: 0)
        }
    }
}
