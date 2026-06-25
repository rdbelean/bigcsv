import SwiftUI
import AppKit
import QuartzCore

/// SwiftUI wrapper around an `NSTableView` that scrolls smoothly over files of
/// any size — including ones large enough to overflow AppKit's backing-store
/// geometry (document height = rows × rowHeight × backingScale must stay under
/// 2³¹ device pixels, which breaks around ~48M rows on a 2× Retina display).
///
/// Strategy: the table's document is *capped* at `cap` physical rows. As long as
/// the file fits within `cap` (which covers the vast majority of real files,
/// including tens of millions of rows), `windowOrigin` stays 0 and this behaves
/// exactly like a plain, fully-native NSTableView — native scroller, native
/// momentum, nothing custom. Only files larger than `cap` "window": the capped
/// page slides over the file, and when the viewport nears a page edge we shift
/// `windowOrigin` and counter-shift the clip by the exact same number of rows so
/// nothing visibly moves. Native scrolling does all the work; we only observe.
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
        /// Max physical rows in the table's document. 20M × 22pt × 3× scale ≈
        /// 1.32e9 device px — safely under 2³¹ — yet large enough that files up
        /// to 20M rows never window (pure native scrolling).
        private let cap = 20_000_000
        private let rowHeight: CGFloat = 22

        private weak var tableView: NSTableView?
        private weak var scrollView: NSScrollView?
        private weak var gutterColumn: NSTableColumn?

        /// Logical (whole-file) row mapped to physical row 0 of the capped page.
        private var windowOrigin = 0
        /// Selection tracked in whole-file (logical) coordinates.
        private var selectedLogical = IndexSet()
        private var lastClipY: CGFloat = -1

        private var isRecentering = false
        private var isReprojecting = false

        private var builtColumnsVersion = -1
        private var lastReloadTime: CFTimeInterval = 0
        private var reloadScheduled = false

        init(document: TableDocument) {
            self.document = document
            super.init()
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        // MARK: View construction

        func makeScrollView() -> NSScrollView {
            let table = NSTableView()
            table.dataSource = self
            table.delegate = self
            table.rowHeight = rowHeight
            table.usesAutomaticRowHeights = false
            table.usesAlternatingRowBackgroundColors = true
            table.allowsColumnResizing = true
            table.allowsColumnReordering = false        // Phase 3
            table.allowsMultipleSelection = true
            table.columnAutoresizingStyle = .noColumnAutoresizing
            table.gridStyleMask = [.solidVerticalGridLineMask]
            table.style = .plain
            table.target = self
            table.doubleAction = #selector(handleDoubleClick)
            self.tableView = table

            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.borderType = .noBorder
            scroll.contentView.postsBoundsChangedNotifications = true
            self.scrollView = scroll

            NotificationCenter.default.addObserver(
                self, selector: #selector(clipBoundsChanged),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView)

            document.onIndexUpdate = { [weak self] in
                self?.rebuildColumnsIfNeeded()
                self?.scheduleReload(force: self?.document.progress.isComplete ?? false)
            }
            document.onScrollToRow = { [weak self] row in
                self?.revealLogical(row)
            }

            rebuildColumnsIfNeeded()
            performReload()
            return scroll
        }

        // MARK: Logical <-> physical mapping

        private func totalRows() -> Int { document.displayRowCount }
        private func pageRows(_ total: Int) -> Int { min(total, cap) }
        private func logical(_ physical: Int) -> Int { windowOrigin + physical }

        // MARK: Columns

        func rebuildColumnsIfNeeded() {
            guard let table = tableView else { return }
            let want = document.columnCount
            guard document.columnsVersion != builtColumnsVersion, want > 0 else { return }
            builtColumnsVersion = document.columnsVersion

            for column in table.tableColumns { table.removeTableColumn(column) }

            let gutter = NSTableColumn(identifier: Self.rowNumberColumnID)
            gutter.title = "#"
            gutter.width = rowNumberWidth()
            gutter.minWidth = 40
            gutter.maxWidth = 200
            table.addTableColumn(gutter)
            gutterColumn = gutter

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

        private func updateGutterWidth() {
            guard let gutter = gutterColumn else { return }
            let needed = rowNumberWidth()
            if gutter.width < needed { gutter.width = needed }
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
            let total = totalRows()
            if windowOrigin > max(0, total - 1) { resetToTop() }   // e.g. after a re-index
            updateGutterWidth()
            tableView?.noteNumberOfRowsChanged()
        }

        private func resetToTop() {
            windowOrigin = 0
            selectedLogical = []
            guard let clip = scrollView?.contentView else { return }
            withoutObserving {
                tableView?.reloadData()
                clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: 0))
                scrollView?.reflectScrolledClipView(clip)
            }
        }

        // MARK: Scroll observation & recentering (only matters for files > cap)

        @objc private func clipBoundsChanged() {
            guard !isRecentering, let clip = scrollView?.contentView else { return }
            let vy = clip.bounds.origin.y
            // Ignore horizontal-only scrolling — it must never trigger a vertical
            // recenter (that was making left/right scrolling choppy).
            if vy == lastClipY { return }
            lastClipY = vy

            let total = totalRows()
            let page = pageRows(total)
            // Fast path: the whole file fits in the page — never window.
            guard total > cap else { return }

            let h = rowHeight
            let vh = clip.bounds.height
            let topPhys = Int(floor(vy / h))
            let botPhys = Int(ceil((vy + vh) / h))
            let visRows = max(1, botPhys - topPhys)
            let band = max(visRows * 4, 20_000)

            var delta = 0
            if topPhys < band && windowOrigin > 0 {
                delta = -min(windowOrigin, cap / 2)
            } else if (page - botPhys) < band && windowOrigin < (total - page) {
                delta = min(total - page - windowOrigin, cap / 2)
            }
            if delta != 0 { performRecenter(delta: delta, clip: clip, vy: vy, vh: vh) }
        }

        private func performRecenter(delta: Int, clip: NSClipView, vy: CGFloat, vh: CGFloat) {
            withoutObserving {
                windowOrigin += delta
                tableView?.reloadData()
                let newPage = min(cap, totalRows() - windowOrigin)
                let maxY = max(0, CGFloat(newPage) * rowHeight - vh)
                let newY = min(max(0, vy - CGFloat(delta) * rowHeight), maxY)
                clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: newY))
                scrollView?.reflectScrolledClipView(clip)
                lastClipY = newY
                reprojectSelection()
            }
        }

        /// Programmatic scroll/reload with our observer and Core Animation quiet.
        private func withoutObserving(_ body: () -> Void) {
            isRecentering = true
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            body()
            CATransaction.commit()
            NSAnimationContext.endGrouping()
            isRecentering = false
        }

        /// Reveal (and select) a whole-file row — used by Go-to-Row (⌘L). Works
        /// across the whole file even when the target is beyond the current page.
        private func revealLogical(_ target: Int) {
            let total = totalRows()
            guard total > 0, let clip = scrollView?.contentView else { return }
            let vh = clip.bounds.height
            let page = pageRows(total)
            let l = min(max(0, target), total - 1)
            let targetWindow = min(max(0, l - cap / 2), max(0, total - page))

            withoutObserving {
                if targetWindow != windowOrigin {
                    windowOrigin = targetWindow
                    tableView?.reloadData()
                }
                let pageH = CGFloat(min(cap, total - windowOrigin)) * rowHeight
                let y = min(max(0, CGFloat(l - windowOrigin) * rowHeight - (vh - rowHeight) / 2),
                            max(0, pageH - vh))
                clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
                scrollView?.reflectScrolledClipView(clip)
                lastClipY = y
                selectedLogical = IndexSet(integer: l)
                reprojectSelection()
            }
        }

        // MARK: Selection (logical)

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isReprojecting, let table = tableView else { return }
            selectedLogical = IndexSet(table.selectedRowIndexes.map { logical($0) })
        }

        private func reprojectSelection() {
            guard let table = tableView else { return }
            isReprojecting = true
            let n = table.numberOfRows
            var physical = IndexSet()
            for l in selectedLogical {
                let p = l - windowOrigin
                if p >= 0 && p < n { physical.insert(p) }
            }
            table.selectRowIndexes(physical, byExtendingSelection: false)
            isReprojecting = false
        }

        @objc private func handleDoubleClick() {
            guard let row = tableView?.clickedRow, row >= 0 else { return }
            document.requestInspector(displayRow: logical(row))
        }

        // MARK: NSTableViewDataSource / Delegate

        func numberOfRows(in tableView: NSTableView) -> Int {
            max(0, min(document.displayRowCount - windowOrigin, cap))
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
                cell.stringValue = "\(logical(row) + 1)"
                cell.alignment = .right
                cell.textColor = .secondaryLabelColor
                cell.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            } else if let columnIndex = Int(id.rawValue) {
                cell.stringValue = document.cell(displayRow: logical(row), column: columnIndex)
                cell.alignment = .left
                cell.textColor = .labelColor
                cell.font = .systemFont(ofSize: 12)
            }
            return cell
        }
    }
}
