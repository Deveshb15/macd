import CoreGraphics
import Foundation

/// One rectangle of the mosaic.
nonisolated struct Tile: Equatable, Sendable {
    /// The node drawn, or `nil` for a tile that merges the tail of a long child list.
    let node: Int?
    /// For a merged tail: its parent and how many children it stands for.
    let parent: Int
    let othersCount: Int
    let rect: CGRect
    /// 0 for children of the view root.
    let depth: Int
    /// The band a subdivided directory keeps for its name. Children sit below it.
    let header: CGRect?
}

nonisolated struct LayoutOptions: Equatable, Sendable {
    var maxDepth = 4
    var padding: CGFloat = 1
    var paddingOuter: CGFloat = 3
    var minTile: CGFloat = 5
    var maxChildren = 96
    var header: CGFloat = 20
    var headerInner: CGFloat = 15
}

/// Name filter: which nodes match, and each node's size counting only matches.
nonisolated struct FilterMatch: Sendable {
    let query: String
    /// Size of what matched beneath each node (its whole size when it matches itself).
    let values: [UInt64]
    let matchesSelf: [Bool]

    init(query: String, tree: DiskTree, metric: SizeMetric) {
        self.query = query
        let needle = query.lowercased()
        var values = [UInt64](repeating: 0, count: tree.count)
        var matches = [Bool](repeating: false, count: tree.count)
        for id in stride(from: tree.count - 1, through: 0, by: -1) {
            if tree.names[id].lowercased().contains(needle) {
                matches[id] = true
                values[id] = tree.value(of: id, metric: metric)
            }
            if let up = tree.parentOf(id), !matches[up] {
                values[up] += values[id]
            }
        }
        self.values = values
        matchesSelf = matches
    }
}

/// Bruls, Huizing and van Wijk's squarified treemap, ported from disktree's `treemap.rs`.
nonisolated enum TreemapLayout {
    static func layout(
        tree: DiskTree, root: Int, area: CGRect, metric: SizeMetric,
        options: LayoutOptions = LayoutOptions(), filter: FilterMatch? = nil
    ) -> [Tile] {
        var tiles: [Tile] = []
        place(tree: tree, node: root, area: area, metric: metric, options: options, filter: filter, depth: 0, into: &tiles)
        return tiles
    }

    private static func place(
        tree: DiskTree, node: Int, area: CGRect, metric: SizeMetric, options: LayoutOptions,
        filter: FilterMatch?, depth: Int, into tiles: inout [Tile]
    ) {
        guard area.width > 0, area.height > 0 else { return }
        var ranked: [(Int, Double)] = tree.children(of: node).compactMap { child in
            let value = filter.map { Double($0.values[child]) } ?? Double(tree.value(of: child, metric: metric))
            return value > 0 ? (child, value) : nil
        }
        guard !ranked.isEmpty else { return }
        ranked.sort { $0.1 > $1.1 }

        let kept = min(ranked.count, options.maxChildren)
        var values = ranked[..<kept].map(\.1)
        var sources: [Int?] = ranked[..<kept].map(\.0)
        let tailCount = ranked.count - kept
        if tailCount > 0 {
            values.append(ranked[kept...].reduce(0) { $0 + $1.1 })
            sources.append(nil)
        }

        for (slot, raw) in squarify(values, in: area).enumerated() {
            let inset = depth == 0 ? options.paddingOuter : options.padding
            let rect = raw.insetBy(dx: inset, dy: inset)
            guard rect.width >= options.minTile, rect.height >= options.minTile else { continue }
            guard let child = sources[slot] else {
                tiles.append(Tile(node: nil, parent: node, othersCount: tailCount, rect: rect, depth: depth, header: nil))
                continue
            }
            let subdividable = tree.isDirectory(child) && depth + 1 < options.maxDepth
            let header = subdividable ? headerBand(rect, options: options, depth: depth) : nil
            tiles.append(Tile(node: child, parent: node, othersCount: 0, rect: rect, depth: depth, header: header))
            if let header {
                let body = CGRect(x: rect.minX, y: header.maxY, width: rect.width, height: rect.maxY - header.maxY)
                // Beneath a match everything shows; above one, only matches.
                let inner = filter.flatMap { $0.matchesSelf[child] ? nil : $0 }
                place(tree: tree, node: child, area: body, metric: metric, options: options, filter: inner, depth: depth + 1, into: &tiles)
            }
        }
    }

    /// The band a directory keeps for its name, or `nil` when its children would have no room.
    static func headerBand(_ rect: CGRect, options: LayoutOptions, depth: Int) -> CGRect? {
        let height = depth == 0 ? options.header : options.headerInner
        guard rect.width >= 44, rect.height - height >= options.minTile * 3 else { return nil }
        return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
    }

    /// Splits `area` into one rectangle per value, proportional to it, in the order of `values`.
    static func squarify(_ values: [Double], in area: CGRect) -> [CGRect] {
        var rects = [CGRect](repeating: .zero, count: values.count)
        let total = values.filter { $0 > 0 }.reduce(0, +)
        guard total > 0, area.width > 0, area.height > 0 else { return rects }

        let order = values.indices.filter { values[$0] > 0 }.sorted { values[$0] > values[$1] }
        let scale = Double(area.width * area.height) / total
        let areas = order.map { values[$0] * scale }

        var free = area
        var start = 0
        while start < areas.count {
            let side = Double(min(free.width, free.height))
            var end = start + 1
            var rowSum = areas[start]
            var rowWorst = worstRatio(areas[start..<end], sum: rowSum, side: side)
            while end < areas.count {
                let candidateSum = rowSum + areas[end]
                let candidateWorst = worstRatio(areas[start...end], sum: candidateSum, side: side)
                if candidateWorst > rowWorst { break }
                rowSum = candidateSum
                rowWorst = candidateWorst
                end += 1
            }

            if free.width >= free.height {
                // A vertical strip on the left; tiles stack top to bottom.
                let stripWidth = min(CGFloat(rowSum / Double(free.height)), free.width)
                var y = free.minY
                for index in start..<end {
                    let height = stripWidth > 0 ? CGFloat(areas[index] / Double(stripWidth)) : 0
                    let clamped = max(0, min(height, free.maxY - y))
                    rects[order[index]] = CGRect(x: free.minX, y: y, width: stripWidth, height: clamped)
                    y += clamped
                }
                free = CGRect(x: free.minX + stripWidth, y: free.minY, width: free.width - stripWidth, height: free.height)
            } else {
                // A horizontal strip along the top; tiles run left to right.
                let stripHeight = min(CGFloat(rowSum / Double(free.width)), free.height)
                var x = free.minX
                for index in start..<end {
                    let width = stripHeight > 0 ? CGFloat(areas[index] / Double(stripHeight)) : 0
                    let clamped = max(0, min(width, free.maxX - x))
                    rects[order[index]] = CGRect(x: x, y: free.minY, width: clamped, height: stripHeight)
                    x += clamped
                }
                free = CGRect(x: free.minX, y: free.minY + stripHeight, width: free.width, height: free.height - stripHeight)
            }
            start = end
        }
        return rects
    }

    /// Worst (largest) aspect ratio in a row of `areas` laid along `side`.
    static func worstRatio(_ areas: ArraySlice<Double>, sum: Double, side: Double) -> Double {
        guard sum > 0, side > 0 else { return .infinity }
        let thickness = sum / side
        return areas.reduce(0) { worst, area in
            guard area > 0 else { return worst }
            let other = area / thickness
            return max(worst, max(thickness / other, other / thickness))
        }
    }

    /// The deepest tile containing `point`. Children follow their parent in the list.
    static func hit(_ tiles: [Tile], at point: CGPoint) -> Tile? {
        tiles.last { $0.rect.contains(point) }
    }
}
