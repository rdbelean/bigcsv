import SwiftUI

/// Multi-column filter bar (Pro). Edits `document.filterSet`; changes are applied
/// (debounced) to stream the matching subset into the row projection.
struct FilterBar: View {
    @ObservedObject var document: TableDocument
    @State private var debounce: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                Text("Show rows where")
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
        .background(.bar)
        .onAppear { if document.filterSet.conditions.isEmpty { addCondition() } }
        .onChange(of: document.filterSet) { _, _ in scheduleApply() }
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
