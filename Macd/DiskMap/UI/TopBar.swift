import SwiftUI

/// Breadcrumbs, the measure controls, then totals, filter, and legend.
struct TopBar: View {
    @Bindable var model: DiskMapModel
    var filterFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Breadcrumbs(model: model)
                Spacer(minLength: 12)
                Picker("Measure", selection: $model.mode) {
                    ForEach(DiskMapModel.Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                Toggle("Hidden files", isOn: Binding(get: { model.includeHidden }, set: { model.setIncludeHidden($0) }))
                Toggle("Apparent size", isOn: $model.apparentSize)
                Stepper("Depth \(model.depth)", onIncrement: { model.setDepth(model.depth + 1) }, onDecrement: { model.setDepth(model.depth - 1) })
                    .fixedSize()
                Menu {
                    Button("Scan Home Folder") { model.startScan(root: model.home) }
                    Button("Scan Whole Disk") { model.scanWholeDisk() }
                    Divider()
                    Button("Rescan") { model.rescan() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .toggleStyle(.checkbox)

            HStack(spacing: 14) {
                Totals(model: model)
                TextField("Filter by name", text: $model.filterText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .focused(filterFocused)
                    .onSubmit { filterFocused.wrappedValue = false }
                    .onExitCommand {
                        model.filterText = ""
                        filterFocused.wrappedValue = false
                    }
                Spacer(minLength: 8)
                Legend(mode: model.mode)
            }
            .font(.callout)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct Breadcrumbs: View {
    let model: DiskMapModel

    var body: some View {
        HStack(spacing: 4) {
            if let tree = model.tree {
                ForEach(Array(model.trail.enumerated()), id: \.element) { index, node in
                    if index > 0 {
                        Text("/").foregroundStyle(.tertiary)
                    }
                    let name = index == 0 ? displayRoot(tree) : tree.names[node]
                    if let up = tree.parentOf(node) {
                        Menu {
                            ForEach(tree.sortedChildren(of: up, by: model.metric).filter { tree.isDirectory($0) }.prefix(40), id: \.self) { sibling in
                                Button("\(tree.names[sibling])  \(Formatters.bytes(tree.allocated[sibling]))") {
                                    model.reveal(sibling)
                                    model.enter(sibling)
                                }
                            }
                        } label: {
                            Text(name)
                        } primaryAction: {
                            model.goTo(trailIndex: index)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    } else {
                        Button(name) { model.goTo(trailIndex: index) }
                            .buttonStyle(.borderless)
                    }
                }
            } else {
                Text("Disk map").font(.headline)
            }
        }
        .lineLimit(1)
    }

    private func displayRoot(_ tree: DiskTree) -> String {
        if tree.rootPath == model.home { return "Home" }
        if tree.rootPath == RemovalPlanner.dataVolume { return "Macintosh HD" }
        return (tree.rootPath as NSString).lastPathComponent
    }
}

private struct Totals: View {
    let model: DiskMapModel

    var body: some View {
        if let tree = model.tree {
            HStack(spacing: 6) {
                Text(Formatters.bytes(tree.allocated[DiskTree.root])).fontWeight(.semibold)
                Text("· \(tree.files[DiskTree.root].formatted()) files").foregroundStyle(.secondary)
                if tree.unreadableCount > 0 {
                    Button("· \(tree.unreadableCount) unreadable") { model.openFullDiskAccessSettings() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Palette.amber)
                        .help("Folders macOS won't let mac'd read. Grant Full Disk Access to include them.")
                }
            }
            .monospacedDigit()
        }
    }
}

struct Legend: View {
    let mode: DiskMapModel.Mode

    var body: some View {
        HStack(spacing: 10) {
            if mode == .age {
                ForEach(Palette.ageLegend, id: \.0) { item in chip(item.0, item.1) }
            } else {
                HStack(spacing: 4) {
                    HatchSwatch()
                    Text("Reclaimable")
                }
                ForEach(Category.legend, id: \.self) { chip($0.label, Palette.color(for: $0)) }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func chip(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }
}

private struct HatchSwatch: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.gray.opacity(0.4)))
            var lines = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                lines.move(to: CGPoint(x: x, y: size.height))
                lines.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 3
            }
            context.stroke(lines, with: .color(.white.opacity(0.5)), lineWidth: 1)
        }
        .frame(width: 10, height: 10)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}
