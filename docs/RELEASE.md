# Releasing BigCSV

BigCSV ships as **two builds from one codebase**:

| | App Store build | Direct / Homebrew build |
|---|---|---|
| Channel | Mac App Store | GitHub Releases + Homebrew cask |
| Signing | App Store (sandbox) | Developer ID + notarization |
| Pro features | sold via StoreKit (€4.99) | **all unlocked, free** |
| Built with | Xcode → Archive | `Scripts/package-release.sh` (`DIRECT_BUILD` flag) |

The split is one compile flag (`DIRECT_BUILD`). The App Store build is the paid
product; the direct build is a free, developer-facing release for reach and
credibility. StoreKit in-app purchase only works through the App Store, so there
is nothing to sell in the direct build — hence it ships fully unlocked.

---

## One-time setup (required before the first direct release)

1. **Developer ID Application certificate** — distinct from the "Apple Development"
   cert. In Xcode: **Settings → Accounts → Manage Certificates → + → Developer ID
   Application**. Requires Apple Developer Program enrollment (team `ML728UQT9W`).

2. **Notary credentials** — create an app-specific password at
   [appleid.apple.com](https://appleid.apple.com) (Sign-In & Security → App-Specific
   Passwords), then store it:
   ```sh
   xcrun notarytool store-credentials bigcsv-notary \
     --apple-id "you@example.com" --team-id ML728UQT9W --password "<app-specific-password>"
   ```

## Cutting a direct release (e.g. 1.0)

```sh
Scripts/package-release.sh 1.0
```

This builds the universal `DIRECT_BUILD` flavor, signs it with hardened runtime,
notarizes + staples, produces `dist/BigCSV-1.0.dmg`, prints the SHA256, and
auto-patches `Casks/bigcsv.rb`.

For a **local-only** test (no Developer ID cert yet — runs on *your* Mac only):
```sh
ALLOW_DEVELOPMENT_SIGNING=1 Scripts/package-release.sh 1.0
```

Then:
1. Commit the patched `Casks/bigcsv.rb`.
2. Create a GitHub release tagged `v1.0` and upload `dist/BigCSV-1.0.dmg`.

## How users install via Homebrew

Until the cask is accepted into the official `homebrew/cask` repo, this repo is
its own tap:

```sh
brew tap rdbelean/bigcsv https://github.com/rdbelean/bigcsv
brew install --cask bigcsv
```

The short form `brew install --cask bigcsv` only works **after** the cask is
accepted upstream — which requires a public, notarized, downloadable release
first. Don't advertise the short form on the landing page until then.

## App Store build (paid)

Built separately in Xcode (**Product → Archive**, no `DIRECT_BUILD` flag) so the
StoreKit `com.rdb.bigcsv.pro` unlock stays active. Covered in Phase 6 distribution.
