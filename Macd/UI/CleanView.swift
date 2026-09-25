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
                working(title: "Checking what can be cleaned…", actionTitle: "Cancel")
            case .ready(let preview):
                ready(preview)
            case .empty:
                message(title: "Nothing to clean", detail: "Your Mac is already tidy.")
            case .cleaning:
                working(title: "Cleaning…", actionTitle: "Stop")
            case .done(let result):
                done(result)
            case .failed(let reason):
                message(title: "Something went wrong", detail: reason)
            }
        }
    }

    private func ready(_ preview: CleanPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Can be freed").foregroundStyle(.secondary)
                Spacer()
                Text(Formatters.bytes(preview.totalBytes))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(preview.categories, id: \.name) { category in
                        CategoryRow(category: category)
                    }
                    if !preview.skipped.isEmpty {
                        SkippedList(items: preview.skipped).padding(.top, 4)
                    }
                }
            }
            .frame(maxHeight: 240)

            Text("Caches, logs, and temporary files only. Documents are never touched.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") { flow.cancel(); onClose() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Clean \(Formatters.bytes(preview.totalBytes))") { flow.confirmClean() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func done(_ result: CleanResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(result.wasCancelled ? "Stopped early. Freed" : "Freed").foregroundStyle(.secondary)
                Spacer()
                Text(Formatters.bytes(result.freedBytes))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
            if !result.skipped.isEmpty {
                SkippedList(items: result.skipped)
            }
            HStack {
                Spacer()
                Button("Done") { flow.dismiss(); onClose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func working(title: String, actionTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
            ProgressView().progressViewStyle(.linear)
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

    private func message(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).fontWeight(.medium)
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
            VStack(alignment: .leading, spacing: 3) {
                ForEach(category.items, id: \.label) { item in
                    HStack {
                        Text(item.label).lineLimit(1)
                        Spacer()
                        Text(item.bytes.map(Formatters.bytes) ?? "—").monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
        } label: {
            HStack {
                Text(category.name)
                Spacer()
                Text(Formatters.bytes(category.totalBytes)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

private struct SkippedList: View {
    let items: [SkippedItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Skipped").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            ForEach(items, id: \.label) { item in
                HStack(alignment: .firstTextBaseline) {
                    Text(item.label).lineLimit(1)
                    Spacer()
                    Text(item.reason).foregroundStyle(.tertiary).lineLimit(1)
                }
                .font(.caption)
            }
        }
    }
}
