import SwiftUI

/// The Free up space flow: preview, confirm, progress, and result.
struct CleanView: View {
    @Bindable var flow: CleanFlow
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch flow.state {
            case .idle:
                EmptyView()
            case .previewing:
                progress(title: "Checking what can be cleaned…", actionTitle: "Cancel")
            case .ready(let preview):
                ready(preview)
            case .empty:
                message(symbol: "sparkles", title: "Nothing to clean", detail: "Your Mac is already tidy.")
            case .cleaning:
                progress(title: "Cleaning…", actionTitle: "Stop")
            case .done(let result):
                done(result)
            case .failed(let reason):
                message(symbol: "exclamationmark.triangle", title: "Something went wrong", detail: reason)
            }
        }
    }

    private func ready(_ preview: CleanPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ready to free")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Formatters.bytes(preview.totalBytes))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(preview.categories, id: \.name) { category in
                        CategoryRow(category: category)
                    }
                    if !preview.skipped.isEmpty {
                        SkippedList(items: preview.skipped)
                    }
                }
            }
            .frame(maxHeight: 260)

            Text("Only caches, logs, and temporary files are removed. Your documents are not touched.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") { flow.cancel(); onClose() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Clean \(Formatters.bytes(preview.totalBytes))") { flow.confirmClean() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func done(_ result: CleanResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(result.wasCancelled ? "Stopped early. Freed \(Formatters.bytes(result.freedBytes))" : "Freed \(Formatters.bytes(result.freedBytes))")
                    .font(.title3.weight(.semibold))
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if !result.skipped.isEmpty {
                SkippedList(items: result.skipped)
            }
            HStack {
                Spacer()
                Button("Done") { flow.dismiss(); onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func progress(title: String, actionTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(title)
            }
            Text(flow.progressLine ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                Spacer()
                Button(actionTitle) { flow.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func message(symbol: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("OK") { flow.dismiss(); onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct CategoryRow: View {
    let category: CleanCategory
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(category.items, id: \.label) { item in
                    HStack {
                        Text(item.label)
                        Spacer()
                        Text(item.bytes.map(Formatters.bytes) ?? "—")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            .padding(.leading, 4)
        } label: {
            HStack {
                Text(category.name)
                Spacer()
                Text(Formatters.bytes(category.totalBytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SkippedList: View {
    let items: [SkippedItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Skipped")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(items, id: \.label) { item in
                HStack(alignment: .firstTextBaseline) {
                    Text(item.label)
                    Spacer()
                    Text(item.reason)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                .font(.caption)
            }
        }
    }
}
