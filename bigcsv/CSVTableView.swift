import SwiftUI
import AppKit
import QuartzCore

/// SwiftUI wrapper around an `NSTableView` that scrolls smoothly over files of
/// ANY size. AppKit crashes ("Invalid view geometry: width is negative") once a
/// table's document view gets tall enough (rows × rowHeight × backingScale near
/// 2³¹ device pixels — well before a big file's true row count). So we never give
/// the table a tall document.
///
/// The table holds only a small **buffer** of physical rows (a window onto the
/// file at `windowOrigin`), and we OWN the vertical scroll: a custom `scrollWheel`
/// accumulates the OS scroll/momentum delta stream into a whole-file `virtualY`,
/// from which we compute which rows the buffer maps to and the exact clip
/// position. There is no native momentum to fight. A custom `NSScroller` reflects
/// whole-file position; horizontal scrolling stays native.
///
/// We draw our OWN fixed column header (the built-in `NSTableHeaderView`
/// mis-positions itself when we drive the clip manually), kept horizontally in
/// sync with the table.
struct CSVTableView: NSViewRepresentable {

    @ObservedObject var document: TableDocument

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.makeContainer()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Data changes flow through the document's callbacks (onIndexUpdate /
        // onSearchChanged / onProjectionChanged). Avoid a forced reload here — it would
        // fire on every @Published change (e.g. streaming match counts) and stutter
        // scrolling. Only make sure the columns exist.
        context.coordinator.rebuildColumnsIfNeeded()
    }

    // MARK: - Scroll view that forwards wheel/keys to the coordinator

    final class SynthScrollView: NSScrollView {
        weak var coordinator: Coordinator?
        override func scrollWheel(with event: NSEvent) { coordinator?.handleScrollWheel(event) }
        override func keyDown(with event: NSEvent) {
            if coordinator?.handleKeyDown(event) != true { super.keyDown(with: event) }
        }
        override var acceptsFirstResponder: Bool { true }
    }

    /// NSTableView that copies the selected rows as TSV on ⌘C (Edit ▸ Copy), and
    /// routes arrow/page/home/end to the coordinator so vertical navigation drives
    /// the synthesized whole-file scroll instead of NSTableView's native
    /// scrollRowToVisible (which would desync our `virtualY` and the frozen pane).
    final class CopyableTableView: NSTableView {
        weak var coordinator: Coordinator?
        @objc func copy(_ sender: Any?) { coordinator?.copySelectionToPasteboard() }
        override func keyDown(with event: NSEvent) {
            if coordinator?.handleKeyDown(event) != true { super.keyDown(with: event) }
        }
    }

    /// Row background: brand zebra, a tinted row-number gutter strip with a right
    /// hairline, a faint bottom separator, and our own green selection (tint + a 3px
    /// left accent bar) — never the default blue system highlight.
    final class BrandRowView: NSTableRowView {
        var zebra = false
        var gutterWidth: CGFloat = 0
        override var isOpaque: Bool { true }
        override func drawSelection(in dirtyRect: NSRect) { }   // handled in drawBackground

        override func drawBackground(in dirtyRect: NSRect) {
            (zebra ? Brand.zebraOdd : Brand.windowBg).setFill()
            bounds.fill()
            if gutterWidth > 0, !isSelected {
                Brand.gutterBg.setFill()
                NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height).fill()
            }
            if isSelected {
                Brand.selectionBg.setFill()
                bounds.fill()
            }
            if gutterWidth > 0 { strokeV(gutterWidth - 0.5, Brand.hairline) }
            strokeH(bounds.height - 0.5, Brand.rowSeparator)
            if isSelected {
                Brand.accent.setFill()
                NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
            }
        }

        private func strokeV(_ x: CGFloat, _ c: NSColor) {
            c.setStroke(); let p = NSBezierPath(); p.lineWidth = 1
            p.move(to: NSPoint(x: x, y: 0)); p.line(to: NSPoint(x: x, y: bounds.height)); p.stroke()
        }
        private func strokeH(_ y: CGFloat, _ c: NSColor) {
            c.setStroke(); let p = NSBezierPath(); p.lineWidth = 1
            p.move(to: NSPoint(x: 0, y: y)); p.line(to: NSPoint(x: bounds.width, y: y)); p.stroke()
        }
    }

    /// A data/gutter cell: a single-line label inset 12pt and vertically centered.
    final class BrandCell: NSView {
        let label = NSTextField(labelWithString: "")
        override init(frame: NSRect) {
            super.init(frame: frame)
            label.lineBreakMode = .byTruncatingTail
            label.cell?.usesSingleLineMode = true
            label.drawsBackground = false
            label.isBordered = false
            addSubview(label)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            let pad: CGFloat = 12, h: CGFloat = 18
            label.frame = NSRect(x: pad, y: (bounds.height - h) / 2,
                                 width: max(0, bounds.width - pad * 2), height: h)
        }
    }

    /// A non-interactive bottom gradient (window-bg → clear) hinting at more rows.
    final class GradientFadeView: NSView {
        private let grad = CAGradientLayer()
        override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer = grad; refresh() }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); grad.frame = bounds }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance(); refresh()
        }
        private func refresh() {
            let prev = NSAppearance.current
            NSAppearance.current = effectiveAppearance
            grad.colors = [Brand.windowBg.withAlphaComponent(0).cgColor, Brand.windowBg.cgColor]
            grad.startPoint = CGPoint(x: 0.5, y: 0)
            grad.endPoint = CGPoint(x: 0.5, y: 1)
            NSAppearance.current = prev
        }
    }

    // MARK: - Fixed, horizontally-syncable column header

    final class ColumnHeaderView: NSView {
        private let content = NSView()
        /// Sort click: passes the DATA column index (gutter ignored).
        var onColumnClick: ((Int) -> Void)?
        /// Resize: (column POSITION incl. gutter, new width).
        var onResize: ((_ position: Int, _ newWidth: CGFloat) -> Void)?
        /// Reorder: move the column at POSITION `from` to POSITION `to`.
        var onReorder: ((_ from: Int, _ to: Int) -> Void)?

        private var columnRanges: [(start: CGFloat, end: CGFloat, dataIndex: Int)] = []
        private var resizingIndex: Int?
        private var pressedIndex: Int?
        private var pressStartX: CGFloat = 0
        private var reordering = false
        private var dropIndicatorX: CGFloat?
        private var trackingArea: NSTrackingArea?
        override var isFlipped: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            clipsToBounds = true
            addSubview(content)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let t = trackingArea { removeTrackingArea(t) }
            let t = NSTrackingArea(rect: bounds, options: [.activeInActiveApp, .mouseMoved, .inVisibleRect],
                                   owner: self, userInfo: nil)
            addTrackingArea(t)
            trackingArea = t
        }

        private func contentX(_ event: NSEvent) -> CGFloat {
            convert(event.locationInWindow, from: nil).x - content.frame.origin.x
        }
        private func boundary(near x: CGFloat) -> Int? {
            for (i, c) in columnRanges.enumerated() where abs(x - c.end) < 5 { return i }
            return nil
        }
        private func column(at x: CGFloat) -> Int? {
            for (i, c) in columnRanges.enumerated() where x >= c.start && x < c.end { return i }
            return nil
        }

        override func mouseMoved(with event: NSEvent) {
            if boundary(near: contentX(event)) != nil { NSCursor.resizeLeftRight.set() }
            else { NSCursor.arrow.set() }
        }

        override func mouseDown(with event: NSEvent) {
            let x = contentX(event)
            if let b = boundary(near: x) { resizingIndex = b; return }
            pressedIndex = column(at: x)        // decide click vs reorder on mouseUp
            pressStartX = x
            reordering = false
        }

        override func mouseDragged(with event: NSEvent) {
            let x = contentX(event)
            if let idx = resizingIndex, idx < columnRanges.count {
                onResize?(idx, max(40, x - columnRanges[idx].start))
                return
            }
            guard let pressed = pressedIndex, columnRanges[pressed].dataIndex >= 0 else { return }
            if !reordering && abs(x - pressStartX) > 6 { reordering = true }
            if reordering, let target = column(at: x), columnRanges[target].dataIndex >= 0 {
                dropIndicatorX = columnRanges[target].start + content.frame.origin.x
                needsDisplay = true
            }
        }

        override func mouseUp(with event: NSEvent) {
            defer {
                resizingIndex = nil; pressedIndex = nil; reordering = false
                dropIndicatorX = nil; needsDisplay = true
            }
            if resizingIndex != nil { return }
            guard let pressed = pressedIndex, columnRanges[pressed].dataIndex >= 0 else { return }
            if reordering {
                if let target = column(at: contentX(event)),
                   columnRanges[target].dataIndex >= 0, target != pressed {
                    onReorder?(pressed, target)
                }
            } else {
                onColumnClick?(columnRanges[pressed].dataIndex)
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            Brand.headerBg.setFill()
            dirtyRect.fill()
            Brand.hairline.setStroke()
            let y = bounds.height - 0.5
            NSBezierPath.strokeLine(from: NSPoint(x: 0, y: y), to: NSPoint(x: bounds.width, y: y))
            if let dx = dropIndicatorX {
                Brand.accent.setStroke()
                let line = NSBezierPath()
                line.lineWidth = 2
                line.move(to: NSPoint(x: dx, y: 0))
                line.line(to: NSPoint(x: dx, y: bounds.height))
                line.stroke()
            }
        }

        func rebuild(columns: [(title: String, width: CGFloat, alignment: NSTextAlignment, dataIndex: Int)],
                     height: CGFloat, spacing: CGFloat, sortColumn: Int?, ascending: Bool) {
            content.subviews.forEach { $0.removeFromSuperview() }
            columnRanges.removeAll(keepingCapacity: true)
            var x: CGFloat = 0
            for col in columns {
                let sorted = col.dataIndex >= 0 && col.dataIndex == sortColumn
                var title = col.title
                if sorted { title += ascending ? "  ▲" : "  ▼" }
                let label = NSTextField(labelWithString: title)
                label.font = Brand.mono(11.5, .semibold)
                label.textColor = sorted ? Brand.accentDeep : Brand.textSecondary
                label.lineBreakMode = .byTruncatingTail
                label.alignment = col.alignment
                label.frame = NSRect(x: x + 2, y: (height - 16) / 2,
                                     width: max(10, col.width - 6), height: 16)
                content.addSubview(label)
                columnRanges.append((start: x, end: x + col.width, dataIndex: col.dataIndex))
                x += col.width + spacing      // match the table's intercell spacing
            }
            content.frame = NSRect(x: content.frame.origin.x, y: 0, width: x, height: height)
        }

        func setHorizontalOffset(_ x: CGFloat) {
            content.frame.origin.x = -x
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {

        static let rowNumberColumnID = NSUserInterfaceItemIdentifier("__row__")

        private let document: TableDocument
        private let rowHeight: CGFloat = Brand.rowHeight
        private let headerHeight: CGFloat = 30
        private let brandRowID = NSUserInterfaceItemIdentifier("__brandrow__")
        private let scrollerWidth: CGFloat = 15
        /// Physical rows the table holds. 200,000 × 22pt × 2 ≈ 8.8M device px —
        /// far under the geometry limit — yet large enough that the window
        /// re-bases only every ~140k rows of travel (a seamless reloadData).
        private let bufferRows = 200_000
        private let overscan = 30_000

        private weak var tableView: NSTableView?
        private weak var scrollView: SynthScrollView?
        private weak var headerView: ColumnHeaderView?
        private weak var gutterColumn: NSTableColumn?
        private var vScroller: NSScroller?

        // Frozen pane (Pro): a left overlay table that shows the gutter + the first
        // `frozenColumnCount` columns, vertically synced to the main table but never
        // scrolled horizontally. Hidden (zero width) when nothing is frozen, so the
        // default experience is byte-for-byte the original single-table behaviour.
        private weak var frozenTable: NSTableView?
        private weak var frozenScroll: SynthScrollView?
        private weak var frozenHeader: ColumnHeaderView?
        private var frozenWidthConstraint: NSLayoutConstraint?
        private var builtFrozenCount = -1

        /// Whole-file vertical scroll offset, in points.
        private var virtualY: CGFloat = 0
        /// Logical row mapped to physical row 0 of the buffer.
        private var windowOrigin = 0
        private var selectedLogical = IndexSet()

        private var isDrivingScroller = false
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

        func makeContainer() -> NSView {
            let table = CopyableTableView()
            table.coordinator = self
            table.dataSource = self
            table.delegate = self
            table.rowHeight = rowHeight
            table.usesAutomaticRowHeights = false
            table.usesAlternatingRowBackgroundColors = false   // we draw brand zebra
            table.selectionHighlightStyle = .none              // we draw brand selection
            table.backgroundColor = Brand.windowBg
            table.gridColor = Brand.columnSeparator
            table.allowsColumnResizing = true
            table.allowsColumnReordering = false        // Phase 3
            table.allowsMultipleSelection = true
            table.columnAutoresizingStyle = .noColumnAutoresizing
            table.gridStyleMask = [.solidVerticalGridLineMask]
            table.style = .plain
            table.headerView = nil                      // we draw our own fixed header
            table.target = self
            table.doubleAction = #selector(handleDoubleClick(_:))
            self.tableView = table

            let scroll = SynthScrollView()
            scroll.coordinator = self
            scroll.documentView = table
            scroll.hasVerticalScroller = false           // we own a whole-file scroller
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = false
            scroll.borderType = .noBorder
            scroll.backgroundColor = Brand.windowBg
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsetsZero
            scroll.contentView.postsFrameChangedNotifications = true
            scroll.translatesAutoresizingMaskIntoConstraints = false
            self.scrollView = scroll

            let header = ColumnHeaderView()
            header.translatesAutoresizingMaskIntoConstraints = false
            self.headerView = header

            let scroller = NSScroller()
            scroller.scrollerStyle = .legacy
            scroller.translatesAutoresizingMaskIntoConstraints = false
            scroller.target = self
            scroller.action = #selector(scrollerAction(_:))
            scroller.knobProportion = 1
            scroller.doubleValue = 0
            self.vScroller = scroller

            // Frozen pane (added last → drawn on top of the main scroll/header).
            let frozenT = CopyableTableView()
            frozenT.coordinator = self
            frozenT.dataSource = self
            frozenT.delegate = self
            frozenT.rowHeight = rowHeight
            frozenT.usesAutomaticRowHeights = false
            frozenT.usesAlternatingRowBackgroundColors = false
            frozenT.selectionHighlightStyle = .none
            frozenT.backgroundColor = Brand.windowBg
            frozenT.gridColor = Brand.columnSeparator
            frozenT.allowsColumnResizing = false
            frozenT.allowsColumnReordering = false
            frozenT.allowsMultipleSelection = true
            frozenT.columnAutoresizingStyle = .noColumnAutoresizing
            frozenT.gridStyleMask = [.solidVerticalGridLineMask]
            frozenT.style = .plain
            frozenT.headerView = nil
            frozenT.target = self
            frozenT.doubleAction = #selector(handleDoubleClick(_:))
            self.frozenTable = frozenT

            let frozenS = SynthScrollView()
            frozenS.coordinator = self
            frozenS.documentView = frozenT
            frozenS.hasVerticalScroller = false
            frozenS.hasHorizontalScroller = false
            frozenS.borderType = .noBorder
            frozenS.automaticallyAdjustsContentInsets = false
            frozenS.contentInsets = NSEdgeInsetsZero
            frozenS.drawsBackground = true                 // opaque: hides the main table's frozen copies
            frozenS.backgroundColor = Brand.windowBg
            frozenS.translatesAutoresizingMaskIntoConstraints = false
            self.frozenScroll = frozenS

            let frozenH = ColumnHeaderView()
            frozenH.translatesAutoresizingMaskIntoConstraints = false
            frozenH.onColumnClick = { [weak self] col in self?.document.toggleSort(column: col) }
            self.frozenHeader = frozenH

            let container = NSView()
            container.addSubview(header)
            container.addSubview(scroll)
            container.addSubview(scroller)
            container.addSubview(frozenS)
            container.addSubview(frozenH)

            let frozenWidth = frozenH.widthAnchor.constraint(equalToConstant: 0)
            self.frozenWidthConstraint = frozenWidth

            NSLayoutConstraint.activate([
                header.topAnchor.constraint(equalTo: container.topAnchor),
                header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                header.heightAnchor.constraint(equalToConstant: headerHeight),

                scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
                scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: scroller.leadingAnchor),
                scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),

                scroller.topAnchor.constraint(equalTo: header.bottomAnchor),
                scroller.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scroller.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                scroller.widthAnchor.constraint(equalToConstant: scrollerWidth),

                frozenH.topAnchor.constraint(equalTo: container.topAnchor),
                frozenH.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                frozenH.heightAnchor.constraint(equalToConstant: headerHeight),
                frozenWidth,

                frozenS.topAnchor.constraint(equalTo: frozenH.bottomAnchor),
                frozenS.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                frozenS.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                frozenS.widthAnchor.constraint(equalTo: frozenH.widthAnchor),
            ])
            frozenS.isHidden = true
            frozenH.isHidden = true

            // Bottom fade hinting at more rows below (non-interactive overlay).
            let fade = GradientFadeView()
            fade.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(fade)
            NSLayoutConstraint.activate([
                fade.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                fade.trailingAnchor.constraint(equalTo: scroller.leadingAnchor),
                fade.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                fade.heightAnchor.constraint(equalToConstant: 40),
            ])

            NotificationCenter.default.addObserver(
                self, selector: #selector(viewGeometryChanged),
                name: NSView.frameDidChangeNotification, object: scroll.contentView)

            document.onIndexUpdate = { [weak self] in
                self?.rebuildColumnsIfNeeded()
                self?.scheduleReload(force: self?.document.progress.isComplete ?? false)
            }
            document.onScrollToRow = { [weak self] row in self?.revealLogical(row) }
            document.onScrollToColumn = { [weak self] col in self?.revealColumn(col) }
            document.onSearchChanged = { [weak self] in self?.tableView?.reloadData() }
            document.onProjectionChanged = { [weak self] in
                guard let self else { return }
                self.rebuildHeader()
                self.rebuildFrozenPane()
                // The visible row set changed (sort order / filtered count). Keep the
                // scroll position (clamped to the new count) so streaming filter
                // results don't yank the view to the top on every update; repaint
                // and re-sync the scroller.
                self.virtualY = min(self.virtualY, self.maxVirtualY())
                self.tableView?.reloadData()
                self.frozenTable?.reloadData()
                self.applyVirtual()
            }
            header.onColumnClick = { [weak self] col in self?.document.toggleSort(column: col) }
            header.onResize = { [weak self] columnIndex, newWidth in
                guard let self, let table = self.tableView,
                      columnIndex >= 0, columnIndex < table.tableColumns.count else { return }
                let col = table.tableColumns[columnIndex]
                col.width = max(col.minWidth, newWidth)
                self.rebuildHeader()
                self.rebuildFrozenPane()
                self.applyVirtual()       // re-sync header offset + horizontal range
            }
            header.onReorder = { [weak self] from, to in
                guard let self, let table = self.tableView,
                      from >= 1, to >= 1,
                      from < table.tableColumns.count, to < table.tableColumns.count else { return }
                table.moveColumn(from, toColumn: to)   // identifiers preserve the data mapping
                self.builtFrozenCount = -1             // positions changed → rebuild the frozen prefix
                self.rebuildHeader()
                self.rebuildFrozenPane()
                self.applyVirtual()
            }

            rebuildColumnsIfNeeded()
            performReload()
            return container
        }

        // MARK: Geometry helpers

        private func totalRows() -> Int { document.displayRowCount }
        private func logical(_ physical: Int) -> Int { windowOrigin + physical }
        private func viewportHeight() -> CGFloat { scrollView?.contentView.bounds.height ?? 0 }
        private func visibleRowCount() -> Int { max(1, Int(ceil(viewportHeight() / rowHeight))) }
        private func maxVirtualY() -> CGFloat {
            max(0, CGFloat(totalRows()) * rowHeight - viewportHeight())
        }

        // MARK: Scroll input

        func handleScrollWheel(_ event: NSEvent) {
            guard let clip = scrollView?.contentView, let table = tableView else { return }

            let unit = event.hasPreciseScrollingDeltas ? CGFloat(1) : rowHeight * 3
            let maxY = maxVirtualY()
            let before = virtualY
            virtualY = min(max(0, virtualY - event.scrollingDeltaY * unit), maxY)
            // Synthesized momentum can coast to a stop just shy of an edge (the OS
            // doesn't know our content bounds). Snap onto the first / last row when
            // scrolling toward and close to that edge.
            let snap = rowHeight * 1.5
            if virtualY < before && virtualY <= snap {
                virtualY = 0
            } else if virtualY > before && virtualY >= maxY - snap {
                virtualY = maxY
            }

            let docWidth = table.frame.width
            let clipWidth = clip.bounds.width
            let newX = min(max(0, clip.bounds.origin.x - event.scrollingDeltaX * unit),
                           max(0, docWidth - clipWidth))
            applyVirtual(clipX: newX)
        }

        func handleKeyDown(_ event: NSEvent) -> Bool {
            let vh = viewportHeight()
            switch event.keyCode {
            case 126: virtualY -= rowHeight                       // up arrow
            case 125: virtualY += rowHeight                       // down arrow
            case 116: virtualY -= max(rowHeight, vh - rowHeight)  // page up
            case 121: virtualY += max(rowHeight, vh - rowHeight)  // page down
            case 115: virtualY = 0                                // home
            case 119: virtualY = maxVirtualY()                    // end
            default: return false
            }
            virtualY = min(max(0, virtualY), maxVirtualY())
            applyVirtual()
            return true
        }

        /// Recompute the window + clip from `virtualY` and paint.
        private func applyVirtual(clipX: CGFloat? = nil) {
            guard let clip = scrollView?.contentView else { return }
            let total = totalRows()
            guard total > 0 else { driveScroller(total: 0); return }

            let topLogical = min(max(0, Int(floor(virtualY / rowHeight))), total - 1)
            let subRow = virtualY - CGFloat(topLogical) * rowHeight
            let visRows = visibleRowCount()
            let maxOrigin = max(0, total - bufferRows)

            // Pin the window to 0 near the top and to the last page near the
            // bottom (those zones scroll with NO re-base); re-base only in the
            // middle when the viewport nears a buffer edge.
            let newOrigin: Int
            if topLogical < 2 * overscan {
                newOrigin = 0
            } else if topLogical > total - 2 * overscan {
                newOrigin = maxOrigin
            } else if topLogical < windowOrigin + overscan
                        || topLogical > windowOrigin + bufferRows - overscan - visRows {
                newOrigin = min(max(0, topLogical - overscan), maxOrigin)
            } else {
                newOrigin = windowOrigin
            }
            if newOrigin != windowOrigin {
                windowOrigin = newOrigin
                tableView?.reloadData()
                frozenTable?.reloadData()
                reprojectSelection()
            }

            // Horizontal clamp to [0, maxX]. The frozen pane is an OPAQUE overlay on
            // the left, so the main table's own copies of the frozen columns simply
            // sit under it — no special left floor is needed (and a floor would push
            // the first non-frozen column under the pane).
            let maxX = max(0, (tableView?.frame.width ?? 0) - clip.bounds.width)
            let x = min(max(0, clipX ?? clip.bounds.origin.x), maxX)
            let y = CGFloat(topLogical - windowOrigin) * rowHeight + subRow
            CATransaction.begin(); CATransaction.setDisableActions(true)
            clip.setBoundsOrigin(NSPoint(x: x, y: y))
            scrollView?.reflectScrolledClipView(clip)
            if let fclip = frozenScroll?.contentView {        // frozen pane: same y, x pinned at 0
                fclip.setBoundsOrigin(NSPoint(x: 0, y: y))
                frozenScroll?.reflectScrolledClipView(fclip)
            }
            CATransaction.commit()
            headerView?.setHorizontalOffset(x)
            driveScroller(total: total)
        }

        // MARK: Frozen pane

        /// Pixel width of the frozen pane (gutter + first N columns), 0 when nothing
        /// is frozen.
        private func frozenWidth() -> CGFloat {
            guard document.frozenColumnCount > 0, let table = tableView else { return 0 }
            let spacing = table.intercellSpacing.width
            let n = min(document.frozenColumnCount + 1, table.tableColumns.count)   // +1 gutter
            var w: CGFloat = 0
            for i in 0..<n { w += table.tableColumns[i].width + spacing }
            return w
        }

        /// Mirror the main table's leading columns into the frozen pane. Cheap when
        /// the structural column count hasn't changed (just refresh width/header/data).
        private func rebuildFrozenPane() {
            guard let main = tableView, let ftable = frozenTable else { return }
            let count = max(0, min(document.frozenColumnCount, document.columnCount))

            if count != builtFrozenCount {
                for c in ftable.tableColumns { ftable.removeTableColumn(c) }
                if count > 0 {
                    for src in main.tableColumns.prefix(count + 1) {   // gutter + count data
                        let col = NSTableColumn(identifier: src.identifier)
                        col.title = src.title
                        col.width = src.width
                        col.minWidth = src.minWidth
                        ftable.addTableColumn(col)
                    }
                }
                builtFrozenCount = count
            } else if count > 0 {
                // keep widths in sync (after a resize) without rebuilding
                for (i, src) in main.tableColumns.prefix(count + 1).enumerated()
                    where i < ftable.tableColumns.count {
                    ftable.tableColumns[i].width = src.width
                }
            }

            frozenScroll?.isHidden = count == 0
            frozenHeader?.isHidden = count == 0
            frozenWidthConstraint?.constant = count > 0 ? frozenWidth() : 0
            if count > 0 {
                rebuildFrozenHeader()
                ftable.reloadData()
            }
        }

        private func rebuildFrozenHeader() {
            guard let ftable = frozenTable else { return }
            let cols = ftable.tableColumns.map { col -> (title: String, width: CGFloat, alignment: NSTextAlignment, dataIndex: Int) in
                if col.identifier == Self.rowNumberColumnID { return ("#", col.width, .right, -1) }
                return (col.title, col.width, .left, Int(col.identifier.rawValue) ?? -1)
            }
            frozenHeader?.rebuild(columns: cols, height: headerHeight,
                                  spacing: ftable.intercellSpacing.width,
                                  sortColumn: document.sortColumn, ascending: document.sortAscending)
            frozenHeader?.setHorizontalOffset(0)        // the frozen header never scrolls
        }

        // MARK: Whole-file scroller

        private func driveScroller(total: Int) {
            guard !isDrivingScroller, let scroller = vScroller else { return }
            let vh = viewportHeight()
            let maxY = maxVirtualY()
            scroller.knobProportion = CGFloat(min(1.0, total > 0 ? Double(vh) / (Double(total) * Double(rowHeight)) : 1))
            scroller.doubleValue = maxY > 0 ? Double(virtualY / maxY) : 0
        }

        @objc private func scrollerAction(_ sender: NSScroller) {
            isDrivingScroller = true
            defer { isDrivingScroller = false }
            let maxY = maxVirtualY()
            let vh = viewportHeight()
            switch sender.hitPart {
            case .knob, .knobSlot: virtualY = CGFloat(sender.doubleValue) * maxY
            case .incrementPage: virtualY += max(rowHeight, vh - rowHeight)
            case .decrementPage: virtualY -= max(rowHeight, vh - rowHeight)
            case .incrementLine: virtualY += rowHeight
            case .decrementLine: virtualY -= rowHeight
            default: break
            }
            virtualY = min(max(0, virtualY), maxY)
            applyVirtual()
        }

        @objc private func viewGeometryChanged() {
            virtualY = min(virtualY, maxVirtualY())
            applyVirtual()
        }

        // MARK: Go-to-row & inspector

        private func revealLogical(_ target: Int) {
            let total = totalRows()
            guard total > 0 else { return }
            let l = min(max(0, target), total - 1)
            let vh = viewportHeight()
            virtualY = min(max(0, CGFloat(l) * rowHeight - (vh - rowHeight) / 2), maxVirtualY())
            applyVirtual()
            selectedLogical = IndexSet(integer: l)
            reprojectSelection()
        }

        /// Scroll horizontally so data column `dataColumn` is at the left edge
        /// (just after any frozen pane).
        func revealColumn(_ dataColumn: Int) {
            // A frozen column is always visible (pinned in the pane) — nothing to do.
            if dataColumn < document.frozenColumnCount { return }
            guard let table = tableView else { return }
            let id = NSUserInterfaceItemIdentifier("\(dataColumn)")
            let spacing = table.intercellSpacing.width
            var x: CGFloat = 0
            for col in table.tableColumns {
                if col.identifier == id { break }
                x += col.width + spacing
            }
            // Land the column just to the right of the frozen pane (applyVirtual clamps).
            applyVirtual(clipX: max(0, x - frozenWidth()))
        }

        @objc private func handleDoubleClick(_ sender: Any?) {
            guard let table = sender as? NSTableView, table.clickedRow >= 0 else { return }
            document.requestInspector(displayRow: logical(table.clickedRow))
        }

        /// Copy the selected rows to the pasteboard as TSV (tab-separated, one row
        /// per line) — pastes straight into Excel/Numbers.
        func copySelectionToPasteboard() {
            guard let table = tableView, !table.selectedRowIndexes.isEmpty else { return }
            var out = [UInt8]()
            for physical in table.selectedRowIndexes {
                // Tab-delimited, with the same RFC-4180 quoting the export uses, so a
                // cell containing a tab or newline doesn't corrupt the paste.
                ExportEngine.appendDelimitedRow(
                    document.rowFields(displayRow: logical(physical)), delimiter: 0x09, into: &out)
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(decoding: out, as: UTF8.self), forType: .string)
        }

        // MARK: Selection (logical)

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isReprojecting, let t = notification.object as? NSTableView else { return }
            selectedLogical = IndexSet(t.selectedRowIndexes.map { logical($0) })
            reprojectSelection()        // mirror between the main table and the frozen pane
        }

        private func reprojectSelection() {
            guard let table = tableView else { return }
            isReprojecting = true
            func physical(forRowCount n: Int) -> IndexSet {
                var s = IndexSet()
                for l in selectedLogical {
                    let p = l - windowOrigin
                    if p >= 0 && p < n { s.insert(p) }
                }
                return s
            }
            table.selectRowIndexes(physical(forRowCount: table.numberOfRows), byExtendingSelection: false)
            table.enumerateAvailableRowViews { rv, _ in rv.needsDisplay = true }   // .none style → repaint
            if let f = frozenTable, frozenScroll?.isHidden == false {
                f.selectRowIndexes(physical(forRowCount: f.numberOfRows), byExtendingSelection: false)
                f.enumerateAvailableRowViews { rv, _ in rv.needsDisplay = true }
            }
            isReprojecting = false
        }

        // MARK: Columns + header

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
            builtFrozenCount = -1          // column set changed → rebuild the frozen prefix
            rebuildHeader()
            rebuildFrozenPane()
        }

        private func rebuildHeader() {
            guard let table = tableView else { return }
            let cols = table.tableColumns.map { col -> (title: String, width: CGFloat, alignment: NSTextAlignment, dataIndex: Int) in
                if col.identifier == Self.rowNumberColumnID { return ("#", col.width, .right, -1) }
                return (col.title, col.width, .left, Int(col.identifier.rawValue) ?? -1)
            }
            headerView?.rebuild(columns: cols, height: headerHeight, spacing: table.intercellSpacing.width,
                                sortColumn: document.sortColumn, ascending: document.sortAscending)
            headerView?.setHorizontalOffset(scrollView?.contentView.bounds.origin.x ?? 0)
        }

        private func rowNumberWidth() -> CGFloat {
            let digits = max(1, String(max(1, document.displayRowCount)).count)
            return max(48, CGFloat(digits) * 9 + 20)
        }

        private func updateGutterWidth() {
            guard let gutter = gutterColumn else { return }
            let needed = rowNumberWidth()
            if gutter.width < needed {
                gutter.width = needed
                rebuildHeader()           // keep header columns aligned with the table
            }
        }

        // MARK: Reload coalescing (~30 Hz, as the index streams in)

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
            if windowOrigin > max(0, total - 1) {          // e.g. after a re-index
                windowOrigin = 0
                virtualY = 0
                selectedLogical = []
            }
            updateGutterWidth()
            tableView?.noteNumberOfRowsChanged()
            frozenTable?.noteNumberOfRowsChanged()
            rebuildFrozenPane()      // keep the frozen pane's widths/data in sync
            applyVirtual()
        }

        // MARK: NSTableViewDataSource / Delegate

        func numberOfRows(in tableView: NSTableView) -> Int {
            max(0, min(document.displayRowCount - windowOrigin, bufferRows))
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = (tableView.makeView(withIdentifier: brandRowID, owner: self) as? BrandRowView)
                ?? { let v = BrandRowView(); v.identifier = brandRowID; return v }()
            view.zebra = (logical(row) & 1) == 1                 // stable absolute-row striping
            view.gutterWidth = tableView.tableColumns.first?.width ?? 0
            return view
        }

        func tableView(_ tableView: NSTableView,
                       viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard let tableColumn else { return nil }
            let id = tableColumn.identifier
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? BrandCell)
                ?? { let c = BrandCell(); c.identifier = id; return c }()
            let label = cell.label

            if id == Self.rowNumberColumnID {
                label.stringValue = document.fileRowNumber(displayRow: logical(row)).formatted()
                label.alignment = .right
                label.textColor = Brand.textMuted
                label.font = Brand.mono(11.5)
            } else if let columnIndex = Int(id.rawValue) {
                let text = document.cell(displayRow: logical(row), column: columnIndex)
                let numeric = document.isNumericColumn(columnIndex)
                label.alignment = numeric ? .right : .left
                label.textColor = Brand.textPrimary
                label.font = numeric ? Brand.mono(13) : Brand.sans(13)
                if let dot = Self.statusDot(text) {
                    label.attributedStringValue = Self.statusAttributed(text, dot: dot)
                } else if let highlighted = highlightedString(text, mono: numeric) {
                    label.attributedStringValue = highlighted
                } else {
                    label.stringValue = text
                }
            }
            return cell
        }

        /// A quiet status dot + label for cells whose value is a recognizable status
        /// word (rendered as "● Paid" etc.). Nil for ordinary cells.
        static func statusDot(_ raw: String) -> NSColor? {
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "paid", "active", "success", "succeeded", "completed", "done", "shipped",
                 "delivered", "approved", "enabled":                      return Brand.dotPaid
            case "pending", "processing", "in progress", "waiting", "queued", "review":
                                                                          return Brand.dotPending
            case "refunded", "cancelled", "canceled", "inactive", "closed", "paused",
                 "archived", "disabled":                                  return Brand.dotRefunded
            case "failed", "error", "declined", "rejected", "overdue":    return Brand.dotFailed
            default:                                                      return nil
            }
        }

        static func statusAttributed(_ raw: String, dot: NSColor) -> NSAttributedString {
            let s = NSMutableAttributedString(string: "● ", attributes: [
                .foregroundColor: dot, .font: Brand.sans(8), .baselineOffset: 1.5,
            ])
            s.append(NSAttributedString(string: raw.trimmingCharacters(in: .whitespaces).capitalized,
                                        attributes: [.foregroundColor: Brand.textSecondary, .font: Brand.sans(13)]))
            return s
        }

        /// Green-highlight every occurrence of the active search query in `text`,
        /// or nil when there's no active query / no match (cell stays plain).
        private func highlightedString(_ text: String, mono: Bool) -> NSAttributedString? {
            let query = document.searchQuery
            guard !query.isEmpty, !text.isEmpty else { return nil }
            let options: String.CompareOptions = document.searchCaseSensitive ? [] : [.caseInsensitive]
            guard text.range(of: query, options: options) != nil else { return nil }

            let attr = NSMutableAttributedString(string: text, attributes: [
                .foregroundColor: Brand.textPrimary,
                .font: mono ? Brand.mono(13) : Brand.sans(13),
            ])
            var from = text.startIndex
            while let r = text.range(of: query, options: options, range: from..<text.endIndex) {
                attr.addAttributes([.backgroundColor: Brand.searchMatchBg, .foregroundColor: Brand.accentText],
                                   range: NSRange(r, in: text))
                if r.upperBound == text.endIndex { break }
                from = r.upperBound
            }
            return attr
        }
    }
}
