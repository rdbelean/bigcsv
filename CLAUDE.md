# BigCSV — Project Context for Claude

> Read this first in every session. It captures the product, the non-negotiable
> architecture, the module map, and the exact build/test/commit rules so any
> session has full context.

## What this is
**BigCSV** — a native macOS app that opens multi-gigabyte CSV/TSV files *instantly*
for **non-technical** users (analysts, PMs, ops) who just want to open, look,
search, sort, and filter a file that makes Excel/Numbers choke. Native + fast +
beautiful + **free core** + a **one-time unlock** (never a subscription).
We are NOT competing with DuckDB / pandas / CLI tools — our buyer does not want a terminal.

- App display name: **BigCSV** (Xcode target is `bigcsv`, bundle id `com.rdb.bigcsv`).
- Min deployment target: **macOS 14**. Universal (arm64 + x86_64). **Sandboxed** (Mac App Store).
- Language: **Swift only**. SwiftUI shell + AppKit data grid. No Electron/Tauri/web views.

## NON-NEGOTIABLE architecture constraints
1. **NEVER load the whole file into memory.** No `String(contentsOf:)`, no `Data(contentsOf:)` full read.
2. **Memory-map** the file (raw `mmap`, `PROT_READ`/`MAP_PRIVATE`). NOT `Data(…,.mappedIfSafe)` (it can silently fall back to a full read).
3. **Lazy record-offset index** built on a background `Task` with progress + total row count. Sparse checkpoint index (offset every K=1024 records) — never a dense per-row array on huge files.
4. **Parse rows ON DEMAND** — only visible rows the table requests get parsed from the mapped bytes.
5. Data grid MUST be **NSTableView** wrapped in `NSViewRepresentable` (cell reuse). SwiftUI is only the shell/toolbar/menus/status bar. We use a **windowed-tiling** table (the NSTableView holds only a buffer of physical rows; a custom scroller maps the full logical row range) so 100M+ row files scroll smoothly — vanilla NSTableView geometry degrades past ~tens of millions of rows.
6. **CSV correctness**: auto-detect delimiter (`, ; \t |`) and encoding (UTF-8 ±BOM, fallback Windows-1252/Latin-1). Quote handling is **positional** — a `"` opens a quoted field only at field start; `""` is an escaped quote only inside an open quoted field; newlines inside quotes are data, not record boundaries. Ragged/short rows tolerated (`cell(row,col)` past field count → `""`, never traps). UTF-16/32 detected → actionable message, full support deferred.
7. **Keep the main thread free** — indexing/parsing batches run off-main (nonisolated core), results published to a `@MainActor` model in coalesced batches.

## Module map
**`bigcsv/Core/`** — pure logic, all `nonisolated`/`Sendable`, compiled into the app AND tested via `swift test`:
- `FileMapper` — owns the `mmap` (`@unchecked Sendable`, `munmap` in deinit), vends byte ranges.
- `RecordIndex` — sparse checkpoint index; `byteRange(forRow:)` via nearest checkpoint + in-block rescan; small LRU cache.
- `LineIndexer` — one quote-aware pass building `RecordIndex`; cancellable; progress.
- `CSVDialect` — delimiter, quote char, encoding, hasHeader.
- `Detection` — `DelimiterDetector`, `EncodingDetector` (sniff first ~1MB only).
- `CSVParser` — `parseRecord(bytes:dialect:) -> [String]`.
- `SearchEngine` — streaming, cancellable; byte prefilter → offset→row → cell verify.
- `Models` — `ColumnInfo`, `CellAddress`, `Match`, `FileStats`, `IndexProgress` (Sendable).

**`bigcsv/`** — app shell (SwiftUI + AppKit, MainActor-default isolation):
- `bigcsvApp` (App + `NSApplicationDelegateAdaptor` for `application(_:open:)`), `AppModel`, `TableDocument`,
  `TableBackend` (protocol), `TilingTableController`, `CSVTableView` (NSViewRepresentable),
  `AppShellView` (replaces `ContentView`), `StatusBarView`, `FindBar`, `Bookmarks`.

**`Tests/BigCSVKitTests/`** — at repo root (NOT in `bigcsv/`), swift-testing. `Package.swift` at root points `BigCSVKit` at `bigcsv/Core`.

### Why a Package AND the synchronized folder
The Xcode project (objectVersion 77) uses `PBXFileSystemSynchronizedRootGroup`: files in `bigcsv/` are auto-included in the app target — **no `project.pbxproj` edits to add source files.** The root `Package.swift` compiles the SAME `bigcsv/Core` files into module `BigCSVKit` for `swift test`. The core compiles in two contexts (app = MainActor-default, package = nonisolated-default), so **every core type must declare isolation explicitly** (`nonisolated`/`Sendable`). Keep both `xcodebuild build` and `swift test` green to catch divergence.

## Open / file handling
- No `DocumentGroup`/`FileDocument` (they read the whole file). Use `WindowGroup` + `application(_:open:)` + `NSOpenPanel` + drag-drop.
- **Free app = single window**; opening a new file **replaces** the current one. Multiple files / tabs is a **paid** unlock.
- Recent files via **security-scoped bookmarks** (`com.apple.security.files.bookmarks.app-scope`).
- Files from `application(_:open:)` / NSOpenPanel are session-granted; bookmark immediately for persistence.

## Build / test / commit rules
**Always export the Xcode toolchain** (CommandLineTools is the active dir otherwise):
```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```
- **Build app (Debug):**
  `xcodebuild -project bigcsv.xcodeproj -scheme bigcsv -configuration Debug -destination 'platform=macOS,arch=arm64' build`
- **Test core logic:** from repo root → `swift test`
- **Release universal:**
  `xcodebuild -project bigcsv.xcodeproj -scheme bigcsv -configuration Release -destination 'generic/platform=macOS' ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build`
  then `lipo -info <…>/bigcsv.app/Contents/MacOS/bigcsv` → expect `arm64 x86_64`.
- **Entitlements check:** `codesign -d --entitlements - <…>/bigcsv.app` → expect app-sandbox + user-selected.read-only + bookmarks.app-scope.

**Rules:**
- Work in **vertical slices**. After each slice: `swift test` green AND clean `xcodebuild build`, then `git commit`.
- **Never declare a phase done without a clean build.** Unit-test the risky logic (parser/indexer edge cases).
- At each CHECKPOINT, stop and tell the user exactly what to do in Xcode (we can't see the GUI) and what to expect.
- Ask before any major architectural deviation.

## Environment facts
- Xcode 26.5 (build 17F42) at `/Applications/Xcode.app`; only the macOS 26.5 SDK is installed (build-for-14 works, can't run-test on 14 here — guard >14 APIs with `if #available`).
- Signing: Apple Development identity present, team `ML728UQT9W`. (App Store distribution signing is Phase 6.)

## Phase status
- [x] Phase 0 — scaffolding & config
- [x] Phase 1 — open → mmap → index → first rows (CHECKPOINT 1 PASSED: 1.2 GB / 15M rows, instant open, smooth first-page scroll, correct quoted/embedded-newline/ragged parsing)
- [ ] Phase 2 — full virtualized (tiling) scroll + delimiter/encoding detection + header toggle + status bar + go-to-row + cell inspector + file-change detection
- [ ] Phase 3 — search + sort + column ops + recent files + dark mode (SHIPPABLE FREE)
- Phase 4 (StoreKit unlock), Phase 5 (paid features), Phase 6 (signing/notarization/distribution) — later.

The full living plan is at `/Users/rdb/.claude/plans/you-are-building-a-cheerful-barto.md`.
