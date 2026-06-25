import SwiftUI
import AppKit
import QuartzCore

/// SwiftUI wrapper around an `NSTableView` that scrolls smoothly over files of
/// ANY size — including 100M+ rows that would otherwise overflow AppKit's
/// backing-store geometry (the document view height = rows × rowHeight × scale
/// must stay under 2³¹ device pixels, which breaks around ~48M rows on Retina).
///
/// Strategy (windowed tiling): the NSTableView's document is *capped* at
/// `cap` (1,000,000) physical rows — a tiny, always-safe document — that acts as
/// a window onto the file at `windowOrigin`. Native NSScrollView keeps doing all
/// the scrolling (real momentum, elastic bounce, precise trackpad). We observe
/// the clip view and, when the viewport nears a page edge, shift `windowOrigin`
/// and counter-shift the clip by the exact same pixels so nothing visibly moves.
/// A fully-owned vertical `NSScroller` represents whole-file position.
///
/// For files ≤ `cap` rows this is byte-identical to a plain table (windowOrigin
/// stays 0); only the largest files ever window.
struct CSVTableView: NSViewRepresentable {

    @ObservedObject var document: TableDocument

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.makeContainer()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.rebuildColumnsIfNeeded()
        context.coordinator.scheduleReload(force: true)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {

        static let rowNumberColumnID = NSUserInterfaceItemIdentifier("__row__")

        private let document: TableDocument
        private let cap = 1_000_000
        private let rowHeight: CGFloat = 22
        private let scrollerWidth: CGFloat = 15

        private weak var tableView: NSTableView?
        private weak var scrollView: NSScrollView?
        private weak var gutterColumn: NSTableColumn?
        private var vScroller: NSScroller?

        /// Logical row currently mapped to physical row 0 of the capped document.
        private var windowOrigin = 0
        /// Selection tracked in whole-file (logical) coordinates.
        private var selectedLogical = IndexSet()

        // Re-entrancy guards.
        private var isRecentering = false
        private var isDrivingScroller = false
        private var isReprojecting = false

        private var builtColumnsVersion = -1
        private var lastReloadTime: CFTimeInterval = 0
        private var reloadScheduled = false

        init(document: TableDocument) {
            self.document = document
            super.init()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: View construction

        func makeContainer() -> NSView {
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
            scroll.hasVerticalScroller = false           // we own a custom whole-file scroller
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = false
            scroll.borderType = .noBorder
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.contentView.postsFrameChangedNotifications = true
            self.scrollView = scroll

            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = true
            scroll.frame = NSRect(x: 0, y: 0, width: 600 - scrollerWidth, height: 400)
            scroll.autoresizingMask = [.width, .height]
            container.addSubview(scroll)

            let scroller = NSScroller(frame: NSRect(x: 600 - scrollerWidth, y: 0,
                                                    width: scrollerWidth, height: 400))
            scroller.scrollerStyle = .legacy
            scroller.knobStyle = .default
            scroller.autoresizingMask = [.minXMargin, .height]
            scroller.target = self
            scroller.action = #selector(scrollerAction(_:))
            scroller.knobProportion = 1
            scroller.doubleValue = 0
            container.addSubview(scroller)
            self.vScroller = scroller

            NotificationCenter.default.addObserver(
                self, selector: #selector(clipChanged),
                name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipChanged),
                name: NSView.frameDidChangeNotification, object: scroll.contentView)

            // Wire document callbacks.
            document.onIndexUpdate = { [weak self] in
                self?.rebuildColumnsIfNeeded()
                self?.scheduleReload(force: self?.document.progress.isComplete ?? false)
            }
            document.onScrollToRow = { [weak self] row in
                self?.revealLogical(row, centered: true)
            }

            rebuildColumnsIfNeeded()
            performReload()
            return container
        }

        // MARK: Logical <-> physical mapping

        private func totalRows() -> Int { document.displayRowCount }
        private func pageRows(_ total: Int) -> Int { min(total, cap) }
        private func logical(_ physical: Int) -> Int { windowOrigin + physical }

        private func visibleRowCount() -> Int {
            guard let clip = scrollView?.contentView else { return 1 }
            return max(1, Int(ceil(clip.bounds.height / rowHeight)))
        }

        private func currentLogicalTop() -> Int {
            guard let clip = scrollView?.contentView else { return windowOrigin }
            return windowOrigin + Int(floor(clip.bounds.origin.y / rowHeight))
        }

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
            // Re-index (the count dropped below our window, e.g. delimiter change)
            // → snap back to the top.
            if windowOrigin > max(0, total - 1) {
                resetToTop()
            }
            updateGutterWidth()
            tableView?.noteNumberOfRowsChanged()
            driveScroller()
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

        // MARK: Scroll observation & recentering

        @objc private func clipChanged() {
            guard !isRecentering, let clip = scrollView?.contentView else { return }
            let h = rowHeight
            let vy = clip.bounds.origin.y
            let vh = clip.bounds.height
            let total = totalRows()
            let page = pageRows(total)
            guard page > 0 else { driveScroller(); return }

            let topPhys = Int(floor(vy / h))
            let botPhys = Int(ceil((vy + vh) / h))
            let visRows = max(1, botPhys - topPhys)
            let band = max(visRows * 4, 20_000)

            var delta = 0
            if topPhys < band && windowOrigin > 0 {
                delta = -min(windowOrigin, cap / 2 - visRows)
            } else if (page - botPhys) < band && windowOrigin < (total - page) {
                delta = min(total - page - windowOrigin, cap / 2 - visRows)
            }
            if delta != 0 {
                performRecenter(delta: delta, clip: clip, vy: vy, vh: vh)
            }
            driveScroller()
        }

        private func performRecenter(delta: Int, clip: NSClipView, vy: CGFloat, vh: CGFloat) {
            withoutObserving {
                windowOrigin += delta
                tableView?.reloadData()
                let newPage = pageRows(totalRows()) - windowOrigin
                let maxY = max(0, CGFloat(max(0, min(cap, newPage))) * rowHeight - vh)
                // Counter-shift by exactly delta rows → zero visible movement.
                let newY = min(max(0, vy - CGFloat(delta) * rowHeight), maxY)
                clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: newY))
                scrollView?.reflectScrolledClipView(clip)
                reprojectSelection()
            }
        }

        /// Run a programmatic scroll/reload without our observer reacting to it
        /// and without Core Animation animating the jump.
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

        // MARK: Whole-file scroller

        private func driveScroller() {
            guard !isDrivingScroller, let clip = scrollView?.contentView, let scroller = vScroller else { return }
            let vy = clip.bounds.origin.y
            let vh = clip.bounds.height
            let total = totalRows()
            let topPhys = Int(floor(vy / rowHeight))
            let visRows = max(1, Int(ceil(vh / rowHeight)))
            let globalTop = Double(windowOrigin + topPhys)
            let denom = Double(max(1, total - visRows))
            scroller.knobProportion = CGFloat(min(1.0, Double(visRows) / Double(max(1, total))))
            scroller.doubleValue = min(1, max(0, globalTop / denom))
        }

        @objc private func scrollerAction(_ sender: NSScroller) {
            isDrivingScroller = true
            defer { isDrivingScroller = false }
            let total = totalRows()
            let vis = visibleRowCount()
            switch sender.hitPart {
            case .knob, .knobSlot:
                let top = Int((sender.doubleValue * Double(max(0, total - vis))).rounded())
                revealLogical(top, asTop: true)
            case .incrementPage:
                revealLogical(currentLogicalTop() + max(1, vis - 1), asTop: true)
            case .decrementPage:
                revealLogical(currentLogicalTop() - max(1, vis - 1), asTop: true)
            case .incrementLine:
                revealLogical(currentLogicalTop() + 1, asTop: true)
            case .decrementLine:
                revealLogical(currentLogicalTop() - 1, asTop: true)
            default:
                break
            }
        }

        /// Scroll so logical row `target` is visible. `asTop` puts it at the top;
        /// otherwise (go-to-row) it is centered.
        private func revealLogical(_ target: Int, asTop: Bool = false, centered: Bool = false) {
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
                var y = CGFloat(l - windowOrigin) * rowHeight
                if centered || (!asTop) { y -= (vh - rowHeight) / 2 }
                y = min(max(0, y), max(0, pageH - vh))
                clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
                scrollView?.reflectScrolledClipView(clip)
                reprojectSelection()
            }
            driveScroller()
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
