import SwiftUI

/// Selection details, "Worth a look", what's marked, and the disk.
struct SidePanel: View {
    @Bindable var model: DiskMapModel
    let hovered: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                DiskSection(model: model)
                // Details follow the pointer, or the keyboard after an arrow key. With
                // neither, show the folder that's open, one level up from its tiles.
                if let tree = model.tree {
                    if let node = hovered ?? model.selection {
                        SelectionSection(model: model, tree: tree, node: node)
                    } else {
                        FolderSummary(model: model, tree: tree)
                    }
                }
                if let tree = model.tree, !model.worthALook.isEmpty {
                    WorthALookSection(model: model, tree: tree)
                }
                if let tree = model.tree, !model.marks.isEmpty {
                    MarkedSection(model: model, tree: tree)
                }
            }
            .padding(16)
        }
        .frame(width: 300)
        .background(Palette.panel)
    }
}

private struct SectionTitle: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if let trailing { Text(trailing).font(.caption.weight(.semibold)).foregroundStyle(Palette.amber) }
        }
    }
}

private struct SelectionSection: View {
    let model: DiskMapModel
    let tree: DiskTree
    let node: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Selection")
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Palette.color(for: tree.category[node])).frame(width: 3, height: 22)
                Text(tree.names[node]).font(.title3.weight(.semibold)).lineLimit(2)
            }
            Text(abbreviated(tree.path(of: node))).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)

            Text(Formatters.bytes(tree.allocated[node]))
                .font(.system(size: 34, weight: .light))
                .monospacedDigit()
            ProgressView(value: share).tint(Palette.amber)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Stat(title: "Of scan", value: Formatters.percent(share))
                    Stat(title: "Files", value: tree.files[node].formatted())
                }
                GridRow {
                    Stat(title: "Last write", value: lastWrite)
                    Stat(title: "Kind", value: kind)
                }
            }

            ForEach(notes, id: \.self) { note in
                Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            }
            if let message = model.markMessage {
                Text(message).font(.caption).foregroundStyle(Palette.danger)
            }

            HStack {
                switch model.panelAction(for: node) {
                case .revealInFinder:
                    Button("Reveal in Finder") { model.revealInFinder(node) }
                case .grantFullDiskAccess:
                    Button("Grant Full Disk Access…") { model.openFullDiskAccessSettings() }
                }
                Spacer()
                if model.planner?.refusal(for: node) == nil || model.marks.isMarked(node) {
                    Button(model.marks.isMarked(node) ? "Unmark" : "Mark") { model.toggleMark(node) }
                }
            }
            .controlSize(.small)
        }
    }

    private var share: Double {
        let total = tree.allocated[DiskTree.root]
        return total == 0 ? 0 : Double(tree.allocated[node]) / Double(total)
    }

    private var lastWrite: String {
        guard tree.newest[node] > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: TimeInterval(tree.newest[node]))
        return date.formatted(.relative(presentation: .named))
    }

    private var kind: String {
        let category = tree.category[node].label
        return tree.reclaim[node].map { "\(category), \($0.label)" } ?? category
    }

    private var notes: [String] {
        var notes: [String] = []
        switch tree.kind[node] {
        case .unreadable: notes.append("macOS won't let mac'd read this folder.")
        case .otherVolume: notes.append("On another volume; not measured.")
        case .smallFiles: notes.append("Files under 1 MB in this folder, grouped.")
        default: break
        }
        if tree.flags[node].contains(.dataless) { notes.append("In iCloud; takes no space on this Mac.") }
        if tree.flags[node].contains(.package) { notes.append("An app or library package.") }
        if let reason = model.planner?.refusal(for: node), tree.kind[node] == .directory || tree.kind[node] == .file {
            notes.append("Can't be removed: \(reason).")
        }
        return notes
    }

    private func abbreviated(_ path: String) -> String {
        path.hasPrefix(model.home) ? "~" + path.dropFirst(model.home.count) : path
    }
}

/// What's open when nothing is hovered: its size, file count, and how fresh the numbers are.
private struct FolderSummary: View {
    let model: DiskMapModel
    let tree: DiskTree

    var body: some View {
        let node = model.viewRoot
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: node == DiskTree.root ? "Scanned folder" : "Open folder")
            Text(tree.path(of: node).replacingOccurrences(of: model.home, with: "~"))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Formatters.bytes(tree.allocated[node])).font(.title3.weight(.medium)).monospacedDigit()
                Text("in \(tree.files[node].formatted()) files").foregroundStyle(.secondary)
            }
            Text("Hover a tile to see what it is.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct Stat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout).lineLimit(2)
        }
    }
}

private struct WorthALookSection: View {
    let model: DiskMapModel
    let tree: DiskTree

    var body: some View {
        let total = model.worthALook.reduce(0) { $0 + $1.bytes }
        let largest = model.worthALook.first?.bytes ?? 1
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Worth a look", trailing: Formatters.bytes(total))
            ForEach(model.worthALook, id: \.node) { candidate in
                Button {
                    model.reveal(candidate.node)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1).fill(Palette.amber.opacity(0.7)).frame(width: 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label(candidate.node)).lineLimit(1).truncationMode(.head)
                            Text(candidate.finding.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(Formatters.bytes(candidate.bytes)).monospacedDigit()
                            ProgressView(value: Double(candidate.bytes) / Double(max(largest, 1)))
                                .tint(Palette.amber.opacity(0.8))
                                .frame(width: 70)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func label(_ node: Int) -> String {
        let up = tree.parentOf(node).map { tree.names[$0] + "/" } ?? ""
        return up + tree.names[node]
    }
}

private struct MarkedSection: View {
    let model: DiskMapModel
    let tree: DiskTree

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Marked", trailing: Formatters.bytes(model.markedBytes))
            ForEach(model.marks.nodes, id: \.self) { node in
                HStack {
                    Text(tree.names[node]).lineLimit(1)
                    Spacer()
                    Text(Formatters.bytes(tree.allocated[node])).monospacedDigit().foregroundStyle(.secondary)
                    Button { model.unmark(node) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }
}

private struct DiskSection: View {
    let model: DiskMapModel

    var body: some View {
        let disk = DiskReader().diskUsage()
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Disk")
            if let disk {
                HStack(alignment: .firstTextBaseline) {
                    Text(Formatters.bytes(disk.freeBytes)).font(.system(size: 30, weight: .light)).monospacedDigit()
                    Text("free").foregroundStyle(.secondary)
                }
                if model.markedBytes > 0 {
                    Text("Up to \(Formatters.bytes(disk.freeBytes + Int64(model.markedBytes))) after removing what's marked")
                        .font(.caption)
                        .foregroundStyle(Palette.amber)
                }
                ProgressView(value: disk.usedFraction).tint(.gray)
                HStack {
                    Text("\(Formatters.bytes(disk.totalBytes - disk.freeBytes)) used")
                    Spacer()
                    Text("\(Formatters.bytes(disk.totalBytes)) total")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Button {
                model.openReview()
            } label: {
                Text(model.marks.isEmpty ? "Mark items to review" : "Review \(model.marks.nodes.count) marked…")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.marks.isEmpty)
        }
    }
}
