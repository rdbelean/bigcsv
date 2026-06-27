import SwiftUI

/// Multi-column filter bar (Pro). Edits `document.filterSet`; changes are applied
/// (debounced) to stream the matching subset into the row projection.
struct FilterBar: View {
    @ObservedObject var document: TableDocument
    @EnvironmentObject var appModel: AppModel
    @State private var debounce: Task<Void, Never>?
    @State private var showSaveDialog = false
    @State private var saveName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("FILTER")
                    .font(Brand.monoFont(10.5, .semibold))
                    .foregroundStyle(Color(Brand.accentText))
                    .tracking(1)
                Text("Show rows where")
                    .font(Brand.sansFont(12.5))
                    .foregroundStyle(Color(Brand.textSecondary))
                Picker("", selection: Binding(
                    get: { document.filterSet.combinator },
                    set: { document.filterSet.combinator = $0 })) {
                    Text("all").tag(FilterSet.Combinator.all)
                    Text("any").tag(FilterSet.Combinator.any)
                }
                .labelsHidden().fixedSize()
                Text("of these match:")

                Spacer()

                Text(countText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                savedMenu
                Button { close() } label: { Image(systemName: "xmark") }
                    .help("Clear filter & close")
            }

            ForEach($document.filterSet.conditions) { $condition in
                ConditionRow(document: document, condition: $condition) {
                    document.filterSet.conditions.removeAll { $0.id == condition.id }
                }
            }

            Button { addCondition() } label: { Label("Add condition", systemImage: "plus") }
                .buttonStyle(.link)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(Brand.filterStripBg))
        .overlay(alignment: .bottom) { Color(Brand.accent).opacity(0.4).frame(height: 1) }
        .onAppear { if document.filterSet.conditions.isEmpty { addCondition() } }
        .onChange(of: document.filterSet) { _, _ in scheduleApply() }
        .alert("Save Filter", isPresented: $showSaveDialog) {
            TextField("Name", text: $saveName)
            Button("Save") {
                appModel.saveFilter(named: saveName, document.filterSet)
                saveName = ""
            }
            Button("Cancel", role: .cancel) { saveName = "" }
        } message: {
            Text("Save the current filter to reuse it later.")
        }
    }

    private var savedMenu: some View {
        Menu {
            if appModel.savedFilters.isEmpty {
                Text("No saved filters")
            } else {
                ForEach(appModel.savedFilters) { sf in
                    Button(sf.name) { apply(sf) }
                }
                Divider()
                Menu("Delete") {
                    ForEach(appModel.savedFilters) { sf in
                        Button(sf.name) { appModel.deleteSavedFilter(sf) }
                    }
                }
            }
            Divider()
            Button("Save Current Filter…") { showSaveDialog = true }
                .disabled(!hasEffectiveCondition)
        } label: {
            Image(systemName: "bookmark")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Saved filters")
    }

    /// At least one condition that would actually filter (has a value if it needs one).
    private var hasEffectiveCondition: Bool {
        document.filterSet.conditions.contains {
            !$0.op.needsValue || !$0.value.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Apply a saved filter, clamping its column indices to this file's columns.
    private func apply(_ sf: SavedFilter) {
        let maxCol = max(0, document.columnCount - 1)
        var fs = sf.filterSet
        fs.conditions = fs.conditions.map { var c = $0; c.column = min(max(0, c.column), maxCol); return c }
        document.filterSet = fs                 // onChange schedules the apply
    }

    private var countText: String {
        let n = document.displayRowCount
        return document.isFiltering ? "\(n.formatted())+ matching…" : "\(n.formatted()) matching rows"
    }

    private func addCondition() {
        document.filterSet.conditions.append(ColumnCondition(column: 0))
    }

    private func close() {
        document.clearFilter()
        document.filterBarVisible = false
    }

    private func scheduleApply() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { document.applyFilter() }
        }
    }
}

/// One "column <operator> value" row in the filter bar.
struct ConditionRow: View {
    @ObservedObject var document: TableDocument
    @Binding var condition: ColumnCondition
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Picker("", selection: $condition.column) {
                ForEach(Array(document.columnTitles.enumerated()), id: \.offset) { index, title in
                    Text(title).tag(index)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 170)

            Picker("", selection: $condition.op) {
                ForEach(FilterOperator.allCases, id: \.self) { op in
                    Text(op.displayName).tag(op)
                }
            }
            .labelsHidden()
            .fixedSize()

            if condition.op.needsValue {
                TextField("value", text: $condition.value)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                Toggle(isOn: $condition.caseSensitive) { Text("Aa") }
                    .toggleStyle(.button)
                    .help("Match case")
            }

            Button { onRemove() } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
