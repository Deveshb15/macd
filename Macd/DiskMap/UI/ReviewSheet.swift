import SwiftUI

/// Text for the permanent-delete confirmation: it names what goes and how much comes back.
enum RemovalSummary {
    static func confirmation(_ items: [(name: String, bytes: UInt64)]) -> String {
        let sorted = items.sorted { $0.bytes > $1.bytes }
        let total = items.reduce(0) { $0 + $1.bytes }
        let named = sorted.prefix(3).map(\.name)
        var list = named.joined(separator: ", ")
        if sorted.count > 3 { list += ", and \(sorted.count - 3) more" }
        let noun = items.count == 1 ? "item" : "items"
        return "Permanently delete \(items.count) \(noun) (\(Formatters.bytes(Int64(clamping: total)))): \(list). This can't be undone."
    }
}

/// Review what's marked, then Move to Trash or Delete Permanently, then see the result.
struct ReviewSheet: View {
    @Bindable var model: DiskMapModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.review {
            case .hidden:
                EmptyView()
            case .reviewing:
                reviewing
            case .confirmingDelete:
                confirming
            case .removing(let mode):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(mode == .trash ? "Moving to the Trash, then rescanning…" : "Deleting, then rescanning…")
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            case .finished(let report):
                finished(report)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    @ViewBuilder private var reviewing: some View {
        if let tree = model.tree {
            Text("Review what's marked").font(.title3.weight(.semibold))
            List {
                ForEach(model.marks.nodes, id: \.self) { node in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tree.names[node])
                            Text(tree.path(of: node)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(Formatters.bytes(tree.allocated[node])).monospacedDigit()
                        Button { model.unmark(node) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Unmark")
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 320)

            HStack {
                Text("Up to \(Formatters.bytes(Int64(clamping: model.markedBytes))) back")
                    .font(.headline)
                Spacer()
            }
            Text("Cloned files and Time Machine snapshots can make the space that comes back smaller.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") { model.closeReview() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Delete Permanently…", role: .destructive) { model.requestPermanentDelete() }
                    .disabled(model.marks.isEmpty)
                Button("Move to Trash") { Task { await model.moveToTrash() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.marks.isEmpty)
            }
        }
    }

    @ViewBuilder private var confirming: some View {
        if let tree = model.tree {
            Label("Delete permanently?", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.danger)
            Text(RemovalSummary.confirmation(model.marks.nodes.map { (tree.names[$0], tree.allocated[$0]) }))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { model.cancelPermanentDelete() }.keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) { Task { await model.confirmPermanentDelete() } }
            }
        }
    }

    @ViewBuilder private func finished(_ report: DiskMapModel.RemovalReport) -> some View {
        Label {
            Text("Freed \(Formatters.bytes(report.freedBytes))").font(.title3.weight(.semibold))
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
        Text("\(report.removedCount) item\(report.removedCount == 1 ? "" : "s") \(report.mode == .trash ? "moved to the Trash" : "deleted"). Marked total was \(Formatters.bytes(Int64(clamping: report.markedBytes))).")
            .foregroundStyle(.secondary)
        if report.mode == .trash {
            Text("Space comes back fully once the Trash is emptied.").font(.caption).foregroundStyle(.secondary)
        }
        if !report.failures.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Not removed").font(.caption.weight(.semibold)).foregroundStyle(Palette.danger)
                ForEach(report.failures, id: \.path) { failure in
                    Text("\((failure.path as NSString).lastPathComponent): \(failure.reason)").font(.caption)
                }
            }
        }
        HStack {
            Spacer()
            Button("Done") { model.closeReview() }.keyboardShortcut(.defaultAction)
        }
    }
}
