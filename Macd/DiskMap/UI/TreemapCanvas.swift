import AppKit
import SwiftUI

/// Draws the mosaic, and turns pointer input into selection, marking, and zoom.
struct TreemapCanvas: View {
    @Bindable var model: DiskMapModel
    @Binding var zoom: ZoomController
    /// The tile under the pointer, when the pointer moved more recently than the keyboard.
    @Binding var hovered: Int?
    /// The canvas size, shared with the window for keyboard zoom.
    @Binding var size: CGSize

    @State private var frameInWindow: CGRect = .zero
    @State private var monitor: Any?

    var body: some View {
        GeometryReader { geometry in
            let area = CGRect(origin: .zero, size: geometry.size)
            let tiles = model.tiles(in: area)
            Canvas(rendersAsynchronously: false) { context, _ in
                draw(tiles, in: &context, viewport: geometry.size)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = tile(at: point, in: tiles)?.node
                case .ended: hovered = nil
                }
            }
            .onTapGesture(count: 2, coordinateSpace: .local) { point in
                guard let node = tile(at: point, in: tiles)?.node else { return }
                model.enter(folderToOpen(node))
                zoom.reset()
            }
            .onTapGesture(count: 1, coordinateSpace: .local) { point in
                guard let node = tile(at: point, in: tiles)?.node else { return }
                if NSEvent.modifierFlags.contains(.control) {
                    model.toggleMark(node)
                } else {
                    model.selection = node
                }
            }
            .contextMenu { contextMenu }
            .onAppear {
                size = geometry.size
                frameInWindow = geometry.frame(in: .global)
                installMonitor(tiles: { model.tiles(in: CGRect(origin: .zero, size: size)) })
            }
            .onChange(of: geometry.size) { _, newSize in
                size = newSize
                frameInWindow = geometry.frame(in: .global)
                zoom.reset()
            }
            .onDisappear { removeMonitor() }
        }
        .background(Palette.background)
        .clipped()
    }

    // MARK: Drawing

    private func draw(_ tiles: [Tile], in context: inout GraphicsContext, viewport: CGSize) {
        guard let tree = model.tree else { return }
        let bounds = CGRect(origin: .zero, size: viewport)
        let marked = Set(model.marks.nodes)
        let now = Int64(Date().timeIntervalSince1970)
        let filtering = model.filter != nil

        for tile in tiles {
            let rect = zoom.transformed(tile.rect)
            guard rect.intersects(bounds), rect.width >= 1, rect.height >= 1 else { continue }
            let radius = min(2, min(rect.width, rect.height) / 5)
            let path = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)

            guard let node = tile.node else {
                context.fill(path, with: .color(Palette.panel))
                drawLabel("\(tile.othersCount) more", detail: nil, in: rect, header: nil, context: &context, dim: true)
                continue
            }

            let isMarked = isMarkedOrInside(node, marked: marked, tree: tree)
            var base = model.mode == .age
                ? Palette.color(forAgeDays: max(0, now - tree.newest[node]) / 86_400)
                : Palette.color(for: tree.category[node])
            if tree.kind[node] == .unreadable || tree.kind[node] == .otherVolume { base = Palette.panel }
            let fill = isMarked ? Palette.danger : base
            let opacity = min(0.95, 0.45 + Double(tile.depth) * 0.10)
            context.fill(path, with: .color(fill.opacity(opacity)))

            if tree.reclaim[node] != nil, !isMarked {
                drawHatch(in: rect, context: &context)
            }
            if let header = tile.header {
                let band = zoom.transformed(header)
                context.fill(Path(roundedRect: band, cornerRadius: radius, style: .continuous), with: .color(fill.opacity(min(1, opacity + 0.2))))
                if tile.depth == 0 {
                    context.fill(Path(CGRect(x: band.minX, y: band.minY, width: band.width, height: 2)), with: .color(fill))
                }
            }
            if filtering, let filter = model.filter, !filter.matchesSelf[node] {
                context.fill(path, with: .color(Palette.background.opacity(0.35)))
            }

            let bytes = Formatters.bytes(tree.value(of: node, metric: model.metric == .files ? .allocated : model.metric))
            let detail = model.mode == .files ? "\(tree.files[node]) files" : bytes
            drawLabel(tree.names[node], detail: detail, in: rect, header: tile.header.map(zoom.transformed), context: &context, dim: false)

            if node == hovered {
                context.stroke(path, with: .color(.white.opacity(0.5)), lineWidth: 1)
            }
            if node == model.selection {
                context.stroke(Path(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: radius, style: .continuous), with: .color(Palette.amber), lineWidth: 2)
            }
        }
    }

    private func drawHatch(in rect: CGRect, context: inout GraphicsContext) {
        var lines = Path()
        let spacing: CGFloat = 7
        var x = rect.minX - rect.height
        while x < rect.maxX {
            lines.move(to: CGPoint(x: x, y: rect.maxY))
            lines.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        var clipped = context
        clipped.clip(to: Path(rect))
        clipped.stroke(lines, with: .color(.white.opacity(0.10)), lineWidth: 1)
    }

    private func drawLabel(_ name: String, detail: String?, in rect: CGRect, header: CGRect?, context: inout GraphicsContext, dim: Bool) {
        let box = header ?? rect
        guard box.width >= 40, box.height >= 14 else { return }
        let title = Text(name).font(.system(size: header != nil && box.height >= 18 ? 12 : 11, weight: .medium))
            .foregroundStyle(.white.opacity(dim ? 0.5 : 0.92))
        let label = context.resolve(title)
        let origin = CGPoint(x: box.minX + 5, y: box.minY + 2)
        var nameSize = label.measure(in: CGSize(width: box.width - 10, height: 16))
        nameSize.width = min(nameSize.width, box.width - 10)
        context.draw(label, in: CGRect(origin: origin, size: nameSize))

        guard let detail else { return }
        let detailText = context.resolve(Text(detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)))
        let detailSize = detailText.measure(in: CGSize(width: box.width, height: 14))
        if header != nil, nameSize.width + detailSize.width + 16 < box.width {
            context.draw(detailText, at: CGPoint(x: box.maxX - 5, y: box.minY + 3), anchor: .topTrailing)
        } else if header == nil, rect.height >= 30 {
            context.draw(detailText, at: CGPoint(x: box.minX + 5, y: box.minY + 17), anchor: .topLeading)
        }
    }

    private func isMarkedOrInside(_ node: Int, marked: Set<Int>, tree: DiskTree) -> Bool {
        guard !marked.isEmpty else { return false }
        var current: Int? = node
        while let id = current {
            if marked.contains(id) { return true }
            current = tree.parentOf(id)
        }
        return false
    }

    // MARK: Hit testing

    private func tile(at point: CGPoint, in tiles: [Tile]) -> Tile? {
        TreemapLayout.hit(tiles, at: zoom.untransformed(point))
    }

    /// Double-clicking a file opens the folder it is in.
    private func folderToOpen(_ node: Int) -> Int {
        guard let tree = model.tree else { return node }
        return tree.isDirectory(node) ? node : (tree.parentOf(node) ?? DiskTree.root)
    }

    @ViewBuilder private var contextMenu: some View {
        if let node = hovered ?? model.selection, let tree = model.tree {
            if tree.isDirectory(node) {
                Button("Open") { model.enter(node) }
            }
            Button(model.marks.isMarked(node) ? "Unmark" : "Mark") { model.toggleMark(node) }
            Button("Reveal in Finder") { model.revealInFinder(node) }
        }
    }

    // MARK: Scroll and pinch

    private func installMonitor(tiles: @escaping () -> [Tile]) {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            guard let window = event.window, window.isKeyWindow, let content = window.contentView else { return event }
            let flipped = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
            guard frameInWindow.contains(flipped) else { return event }
            let point = CGPoint(x: flipped.x - frameInWindow.minX, y: flipped.y - frameInWindow.minY)

            if event.type == .scrollWheel, event.modifierFlags.contains(.shift) {
                zoom.pan(dx: event.scrollingDeltaX + event.scrollingDeltaY, dy: 0, viewport: size)
                return nil
            }
            let delta = event.type == .magnify ? event.magnification * 60 : event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8)
            guard delta != 0 else { return nil }
            let layoutPoint = zoom.untransformed(point)
            let folder = tiles().first { $0.depth == 0 && $0.rect.contains(layoutPoint) && ($0.node.map { model.tree?.isDirectory($0) ?? false } ?? false) }
            switch zoom.zoom(delta: delta, at: point, viewport: size, folder: folder.map { ($0.node!, $0.rect) }) {
            case .enter(let node): model.enter(node)
            case .goUp: model.goUp()
            case .none: break
            }
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
