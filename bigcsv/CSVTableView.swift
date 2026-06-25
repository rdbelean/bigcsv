import SwiftUI
import AppKit
import QuartzCore

/// SwiftUI wrapper around an `NSTableView` (cell reuse, lazy row views) inside an
/// `NSScrollView`. The table reads cell values on demand from `TableDocument` and
/// refreshes its row count (coalesced to ~30 Hz) as the background index streams
/// in. Fixed row height + cheap `NSTextField` cells keep scrolling O(visible).
///
/// Phase 1 uses the real row count directly, which is smooth for the first
/// screens and for files up to several million rows. The windowed-tiling backend
/// for 100M+ row files lands in Phase 2 behind this same view.
struct CSVTableView: NSViewRepresentable {

    @ObservedObject var document: TableDocument

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.rebuildColumnsIfNeeded()
        context.coordinator.scheduleReload(force: true)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {

        static let rowNumberColumnID = NSUserInterfaceItemIdentifier("__row__")

        private let document: TableDocument
        private weak var tableView: NSTableView?
        private var builtColumnsVersion = -1

        private var lastReloadTime: CFTimeInterval = 0
        private var reloadScheduled = false

        init(document: TableDocument) {
            self.document = document
            super.init()
        }

        func makeScrollView() -> NSScrollView {
            let table = NSTableView()
            table.dataSource = self
            table.delegate = self
            table.rowHeight = 22
            table.usesAutomaticRowHeights = false
            table.usesAlternatingRowBackgroundColors = true
            table.allowsColumnResizing = true
            table.allowsColumnReordering = false        // Phase 3
            table.allowsMultipleSelection = true
            table.columnAutoresizingStyle = .noColumnAutoresizing
            table.gridStyleMask = [.solidVerticalGridLineMask]
            table.style = .plain
            self.tableView = table

            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder

            // Refresh the row count as the index grows.
            document.onIndexUpdate = { [weak self] in
                self?.rebuildColumnsIfNeeded()
                self?.scheduleReload(force: self?.document.progress.isComplete ?? false)
            }

            rebuildColumnsIfNeeded()
            performReload()
            return scroll
        }

        // MARK: Columns

        func rebuildColumnsIfNeeded() {
            guard let table = tableView else { return }
            let want = document.columnCount
            guard document.columnsVersion != builtColumnsVersion, want > 0 else { return }
            builtColumnsVersion = document.columnsVersion

            for column in table.tableColumns { table.removeTableColumn(column) }

            // Leading row-number gutter.
            let gutter = NSTableColumn(identifier: Self.rowNumberColumnID)
            gutter.title = "#"
            gutter.width = rowNumberWidth()
            gutter.minWidth = 40
            gutter.maxWidth = 200
            table.addTableColumn(gutter)

            for i in 0..<want {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(i)"))
                col.title = i < document.columnTitles.count ? document.columnTitles[i] : "Column \(i + 1)"
                col.width = 160
                col.minWidth = 40
                table.addTableColumn(col)
            }
            table.reloadData()
        }

        private func rowNumberWidth() -> CGFloat {
            let digits = max(1, String(max(1, document.displayRowCount)).count)
            return max(48, CGFloat(digits) * 9 + 20)
        }

        // MARK: Reload coalescing (~30 Hz)

        func scheduleReload(force: Bool) {
            let now = CACurrentMediaTime()
            let minInterval = 1.0 / 30.0
            if force || now - lastReloadTime >= minInterval {
                performReload()
            } else if !reloadScheduled {
                reloadScheduled = true
                let delay = minInterval - (now - lastReloadTime)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.reloadScheduled = false
                    self?.performReload()
                }
            }
        }

        private func performReload() {
            lastReloadTime = CACurrentMediaTime()
            tableView?.noteNumberOfRowsChanged()
        }

        // MARK: NSTableViewDataSource / Delegate

        func numberOfRows(in tableView: NSTableView) -> Int {
            document.displayRowCount
        }

        func tableView(_ tableView: NSTableView,
                       viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard let tableColumn else { return nil }
            let id = tableColumn.identifier

            let cell: NSTextField
            if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField {
                cell = reused
            } else {
                cell = NSTextField(labelWithString: "")
                cell.identifier = id
                cell.lineBreakMode = .byTruncatingTail
                cell.isBordered = false
                cell.drawsBackground = false
                cell.font = .systemFont(ofSize: 12)
            }

            if id == Self.rowNumberColumnID {
                cell.stringValue = "\(row + 1)"
                cell.alignment = .right
                cell.textColor = .secondaryLabelColor
                cell.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            } else if let columnIndex = Int(id.rawValue) {
                cell.stringValue = document.cell(displayRow: row, column: columnIndex)
                cell.alignment = .left
                cell.textColor = .labelColor
                cell.font = .systemFont(ofSize: 12)
            }
            return cell
        }
    }
}
