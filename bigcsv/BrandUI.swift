import SwiftUI

// MARK: - Chip surface

/// The shared "chip" look — a 30pt pill with a hairline ring; green-tinted when
/// active, solid accent (ink text) when primary. Used by both buttons and menus.
private struct ChipSurface: ViewModifier {
    var active = false
    var primary = false
    func body(content: Content) -> some View {
        content
            .font(Brand.sansFont(12.5, .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(bg, in: RoundedRectangle(cornerRadius: Brand.radiusControl))
            .overlay(RoundedRectangle(cornerRadius: Brand.radiusControl).strokeBorder(ring, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Brand.radiusControl))
    }
    private var fg: Color { primary ? Color(Brand.onAccent) : (active ? Color(Brand.accentText) : Color(Brand.textSecondary)) }
    private var bg: Color { primary ? Color(Brand.accent) : (active ? Color(Brand.accent).opacity(0.16) : .clear) }
    private var ring: Color { primary ? .clear : (active ? Color(Brand.accent) : Color(Brand.hairline)) }
}

private extension View {
    func chip(active: Bool = false, primary: Bool = false) -> some View {
        modifier(ChipSurface(active: active, primary: primary))
    }
}

/// A chip-styled action button.
struct BrandChip: View {
    let title: String
    let systemImage: String
    var active = false
    var primary = false
    var help = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .imageScale(.small)
                .chip(active: active, primary: primary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A square icon-only chip (sidebar / open).
struct BrandIconButton: View {
    let systemImage: String
    var help = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(Brand.textSecondary))
                .frame(width: 30, height: 30)
                .background(.clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(Brand.hairline), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Search field

struct BrandSearchField: View {
    @ObservedObject var document: TableDocument
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5))
                .foregroundStyle(Color(focused ? Brand.accentText : Brand.textSecondary))
            TextField("", text: $document.searchQuery,
                      prompt: Text("Search \(document.displayRowCount.formatted()) rows…")
                        .foregroundColor(Color(Brand.placeholder)))
                .textFieldStyle(.plain)
                .font(Brand.sansFont(13.5))
                .foregroundStyle(Color(Brand.textPrimary))
                .focused($focused)
                .onSubmit { document.nextMatch() }
                .onChange(of: document.searchQuery) { _, _ in document.performSearch() }
            if !document.searchQuery.isEmpty {
                Text(matchText)
                    .font(Brand.monoFont(11.5))
                    .foregroundStyle(Color(Brand.accentText))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color(Brand.accent).opacity(0.18), in: Capsule())
            } else {
                Text("⌘F")
                    .font(Brand.monoFont(11))
                    .foregroundStyle(Color(Brand.textMuted))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color(Brand.hairline), in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color(focused ? Brand.windowBg : Brand.searchBg),
                    in: RoundedRectangle(cornerRadius: Brand.radiusControl))
        .overlay(RoundedRectangle(cornerRadius: Brand.radiusControl)
            .strokeBorder(Color(focused ? Brand.accent : Brand.hairline), lineWidth: focused ? 1.5 : 1))
        // ⌘F (which sets findBarVisible) focuses this field instead of a separate bar.
        .onChange(of: document.findBarVisible) { _, show in
            if show { focused = true; document.findBarVisible = false }
        }
    }

    private var matchText: String {
        if document.matchRows.isEmpty { return document.isSearching ? "searching…" : "no matches" }
        let total = document.matchRows.count
        return document.isSearching ? "\(total)+ matches" : "\(total) matches"
    }
}

// MARK: - Toolbar strip

/// The custom unified toolbar strip (open + format · search · action chips).
struct BrandToolbar: View {
    @ObservedObject var document: TableDocument
    @EnvironmentObject var appModel: AppModel
    @EnvironmentObject var purchase: PurchaseManager

    var body: some View {
        HStack(spacing: 8) {
            BrandIconButton(systemImage: "folder", help: "Open a CSV or TSV file (⌘O)") {
                appModel.presentOpenPanel()
            }
            formatMenu

            BrandSearchField(document: document)
                .frame(maxWidth: .infinity)

            BrandChip(title: "Filter",
                      systemImage: document.filterSet.isEmpty ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill",
                      active: document.filterBarVisible || !document.filterSet.isEmpty,
                      help: purchase.isUnlocked ? "Filter rows" : "Filter rows (Pro)") {
                purchase.requireUnlock(.filter) { document.filterBarVisible.toggle() }
            }
            sortMenu
            columnsMenu
            BrandChip(title: "Stats", systemImage: "chart.bar",
                      active: document.statsSheetVisible,
                      help: purchase.isUnlocked ? "Column statistics" : "Statistics (Pro)") {
                purchase.requireUnlock(.statistics) { document.statsSheetVisible = true }
            }
            .disabled(!document.canComputeStats)
            .opacity(document.canComputeStats ? 1 : 0.45)

            BrandChip(title: "Export", systemImage: "square.and.arrow.up", primary: true,
                      help: purchase.isUnlocked ? "Export the current view" : "Export (Pro)") {
                purchase.requireUnlock(.export) { document.exportSheetVisible = true }
            }
            .disabled(!document.canExport)
            .opacity(document.canExport ? 1 : 0.45)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(Brand.barBg))
        .overlay(alignment: .bottom) { Color(Brand.hairline).frame(height: 1) }
    }

    private var formatMenu: some View {
        Menu {
            Picker("Delimiter", selection: Binding(get: { document.dialect.delimiter },
                                                   set: { document.setDelimiter($0) })) {
                ForEach(Delimiter.allCases, id: \.self) { d in
                    Text("\(d.displayName)  (\(d.displaySymbol))").tag(d)
                }
            }
            Picker("Encoding", selection: Binding(get: { document.dialect.encoding },
                                                  set: { document.setEncoding($0) })) {
                ForEach(TextEncoding.allCases, id: \.self) { e in Text(e.displayName).tag(e) }
            }
            Divider()
            Toggle("First Row Is Header", isOn: Binding(get: { document.dialect.hasHeader },
                                                        set: { document.setHasHeader($0) }))
        } label: {
            Image(systemName: "tablecells.badge.ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(Brand.textSecondary))
                .frame(width: 30, height: 30)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(Brand.hairline), lineWidth: 1))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Delimiter, encoding, and header options")
    }

    private var sortMenu: some View {
        Menu {
            ForEach(Array(document.columnTitles.enumerated()), id: \.offset) { i, title in
                Button {
                    document.toggleSort(column: i)
                } label: {
                    if document.sortColumn == i {
                        Label(title.isEmpty ? "Column \(i + 1)" : title,
                              systemImage: document.sortAscending ? "arrow.up" : "arrow.down")
                    } else {
                        Text(title.isEmpty ? "Column \(i + 1)" : title)
                    }
                }
            }
            if document.sortColumn != nil {
                Divider()
                Button("Clear Sort") { document.clearSort() }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
                .labelStyle(.titleAndIcon).imageScale(.small)
                .chip(active: document.sortColumn != nil)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(document.columnCount == 0)
    }

    private var columnsMenu: some View {
        Menu {
            Picker("Freeze Columns", selection: Binding(
                get: { document.frozenColumnCount },
                set: { v in purchase.requireUnlock(.freezeColumns) { document.frozenColumnCount = v } })) {
                Text("Don’t freeze").tag(0)
                ForEach(1...max(1, min(3, document.columnCount)), id: \.self) { n in
                    Text(n == 1 ? "Freeze first column" : "Freeze first \(n) columns").tag(n)
                }
            }
            Divider()
            Button("Go to Column…") { appModel.showGoToColumn = true }
        } label: {
            Label("Columns", systemImage: document.frozenColumnCount > 0 ? "pin.fill" : "pin")
                .labelStyle(.titleAndIcon).imageScale(.small)
                .chip(active: document.frozenColumnCount > 0)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(document.columnCount == 0)
    }
}
