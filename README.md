<div align="center">
  <img src="docs/logo.png" width="112" alt="BigCSV logo">
  <h1>BigCSV</h1>
  <p><strong>Open multi gigabyte CSV and TSV files instantly on macOS.</strong></p>
  <p>
    <img alt="Platform" src="https://img.shields.io/badge/macOS-14%2B-0E1110">
    <img alt="Swift" src="https://img.shields.io/badge/Swift-5-A3E635?labelColor=0E1110">
    <img alt="Arch" src="https://img.shields.io/badge/universal-arm64%20%2B%20x86__64-0E1110">
    <img alt="Sandboxed" src="https://img.shields.io/badge/App%20Store-sandboxed-A3E635?labelColor=0E1110">
  </p>
  <p><a href="https://bigcsv.app">bigcsv.app</a></p>
</div>

---

BigCSV is a native macOS app that opens CSV and TSV files of any size in a fraction of a second, even when they hold tens of millions of rows. It is built for people who just want to look at a big data file (analysts, PMs, ops, engineers) without reaching for a terminal, a database, or a spreadsheet that freezes.

No row limits. No import step. No data ever leaves your Mac.

## Features

### Free

* Open CSV and TSV files of any size, instantly
* Smooth scrolling across tens of millions of rows
* Full text search with live match navigation
* Sort by any column (numeric or text)
* Automatic delimiter and encoding detection
* Resize, reorder, and inspect columns
* Recent files and dark mode

### Pro (a one time unlock, never a subscription)

* Filter by multiple columns
* Export to CSV, TSV, JSON, and Excel (xlsx)
* Column statistics: sum, mean, min, max, median
* Freeze columns and jump to any column
* Open multiple files in tabs
* Saved filters

## Why it stays fast

BigCSV never loads the whole file into memory.

* The file is memory mapped, so the operating system pages in only what you actually read.
* A sparse record offset index is built in the background, so the first rows appear within milliseconds while indexing continues.
* Only the rows currently on screen are parsed, on demand.
* The data grid is an `NSTableView` that holds a small buffer of physical rows wrapped in a synthesized whole file scroller. A normal table view crashes once the document gets tall enough (around tens of millions of rows on a Retina display); this design stays smooth well past 100 million.
* The CSV parser is positional and quote aware: embedded delimiters, embedded newlines, escaped quotes, ragged rows, and `UTF-8` or `Windows-1252` encodings all parse correctly.

## Install

* **Mac App Store:** coming soon.
* **Build from source:** see below.

## Build and test

Requirements: macOS 14 or later, Xcode 16 or newer.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Build the app (Debug)
xcodebuild -project bigcsv.xcodeproj -scheme bigcsv \
  -configuration Debug -destination 'platform=macOS,arch=arm64' build

# Run the core logic test suite
swift test
```

The same `bigcsv/Core` sources are compiled into the app target and, through the root `Package.swift`, into a `BigCSVKit` module that `swift test` exercises. Keep both green.

## Architecture

```
bigcsv/Core/        Pure logic, nonisolated and Sendable, tested via swift test
  FileMapper          owns the mmap and vends byte ranges
  LineIndexer         one quote aware pass that builds the sparse index
  RecordIndex         checkpoint offsets plus an LRU cache
  CSVParser           positional, quote aware record parsing
  Detection           delimiter and encoding sniffing
  SearchEngine        streaming, cancellable full text search
  SortEngine          type aware column sort permutations
  FilterEngine        streaming multi column filter
  StatsEngine         single pass column statistics
  ExportEngine        streaming CSV, TSV, JSON export
  XLSXExporter        hand written Excel writer (zero dependencies)
  ExportRowSource     shared, hardened row enumeration for the exporters

bigcsv/             SwiftUI shell plus the AppKit data grid
  bigcsvApp, AppModel, TableDocument
  CSVTableView        the windowed, synthesized scroll table
  AppShellView, BrandUI, Brand
  PurchaseManager     StoreKit 2 unlock
```

The core logic ships with a swift-testing suite of more than 140 tests covering the parser, indexer, detection, search, sort, filter, export (including the XLSX writer), and statistics.

## Status

BigCSV is feature complete and on its way to the Mac App Store. A free direct build for Homebrew is planned.

## License

BigCSV is a commercial application. The source is published here for transparency. All rights reserved.
