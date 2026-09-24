import SwiftUI

/// Read-only view of what is using disk space, largest first, with folder drill-down.
struct AnalyzeWindow: View {
    @Bindable var model: AnalyzeModel

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbs
            Divider()
            content
        }
        .frame(minWidth: 520, minHeight: 420)
        .onAppear {
            if model.state == .idle { model.start() }
        }
        .toolbar {
            ToolbarItem {
                Button { model.refresh() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
            }
        }
    }

    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(model.trail.enumerated()), id: \.offset) { index, path in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button(displayName(path)) { model.goBack(to: index) }
                        .buttonStyle(.plain)
                        .foregroundStyle(index == model.trail.count - 1 ? .primary : .secondary)
                        .disabled(index == model.trail.count - 1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle:
            Color.clear
        case .loading(let path):
            VStack(spacing: 10) {
                ProgressView()
                Text("Measuring \(displayName(path))…")
                    .foregroundStyle(.secondary)
                Button("Cancel") { model.cancel() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("Couldn't analyze this folder", systemImage: "exclamationmark.triangle", description: Text(message))
        case .loaded(let listing):
            if listing.entries.isEmpty {
                ContentUnavailableView("Nothing here", systemImage: "folder")
            } else {
                List(listing.entries) { entry in
                    EntryRow(entry: entry, total: listing.totalSize)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { model.open(entry) }
                        .contextMenu {
                            if entry.isDirectory {
                                Button("Open") { model.open(entry) }
                            }
                            Button("Reveal in Finder") { model.revealInFinder(entry) }
                        }
                }
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Text("\(Formatters.bytes(listing.totalSize)) in \(displayName(listing.path))")
                        Spacer()
                        Text("Double-click a folder to open it")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar)
                }
            }
        }
    }

    private func displayName(_ path: String) -> String {
        path == AnalyzeModel.homePath ? "Home" : (path as NSString).lastPathComponent
    }
}

private struct EntryRow: View {
    let entry: DiskEntry
    let total: Int64

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                ProgressView(value: total > 0 ? Double(entry.size) / Double(total) : 0)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
            }
            Text(Formatters.bytes(entry.size))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}
