import Foundation

/// Which distribution this binary was built for.
///
/// BigCSV ships as **two builds from one codebase**, selected by the
/// `DIRECT_BUILD` Swift compilation condition (set only in the direct-distribution
/// build configuration):
///
/// - **App Store build** (`DIRECT_BUILD` *unset*): sandboxed, the Pro unlock is
///   sold via StoreKit (`PurchaseManager`). This is the paid product.
/// - **Direct / Homebrew build** (`DIRECT_BUILD` *set*): Developer-ID-signed +
///   notarized, distributed via GitHub Releases and a Homebrew cask. Every Pro
///   feature is unlocked unconditionally and the purchase UI is hidden — StoreKit
///   in-app purchase only works through the App Store, so there is nothing to sell
///   here. The reach/credibility of a free developer-facing build is the point.
///
/// Defaulting to `false` means the App Store behaviour is the safe default: a build
/// that forgets to define the flag stays paid, never accidentally free.
enum BuildFlavor {
    static let isDirectFreeBuild: Bool = {
        #if DIRECT_BUILD
        return true
        #else
        return false
        #endif
    }()
}
