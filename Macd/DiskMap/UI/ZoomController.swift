import CoreGraphics
import Foundation

/// Continuous zoom toward the pointer, like disktree: magnify until the folder under the
/// pointer fills the view, then go into it. Pure state, so it can be tested.
struct ZoomController: Equatable {
    enum Outcome: Equatable {
        case none
        case enter(Int)
        case goUp
    }

    static let maxScale: CGFloat = 40
    /// How much of the viewport a folder must cover before zooming goes into it.
    static let enterCoverage: CGFloat = 0.9
    /// Accumulated outward scroll at scale 1 before it counts as "go up".
    static let upThreshold: CGFloat = 30

    private(set) var scale: CGFloat = 1
    /// Screen = tile × scale + offset.
    private(set) var offset: CGPoint = .zero
    private var outwardAtRest: CGFloat = 0

    var isZoomed: Bool { scale > 1.0001 }

    func transformed(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * scale + offset.x, y: rect.minY * scale + offset.y,
               width: rect.width * scale, height: rect.height * scale)
    }

    /// The layout point under a screen point.
    func untransformed(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale)
    }

    /// Magnifies by `factor`, keeping `point` fixed on screen.
    mutating func magnify(by factor: CGFloat, at point: CGPoint, viewport: CGSize) {
        let newScale = min(max(scale * factor, 1), Self.maxScale)
        let ratio = newScale / scale
        offset = CGPoint(x: point.x - (point.x - offset.x) * ratio, y: point.y - (point.y - offset.y) * ratio)
        scale = newScale
        clamp(viewport)
    }

    mutating func pan(dx: CGFloat, dy: CGFloat, viewport: CGSize) {
        offset.x += dx
        offset.y += dy
        clamp(viewport)
    }

    mutating func reset() {
        scale = 1
        offset = .zero
        outwardAtRest = 0
    }

    /// Handles one scroll or pinch step. `folder` is the top-level folder tile under the
    /// pointer (layout coordinates), if any.
    mutating func zoom(
        delta: CGFloat, at point: CGPoint, viewport: CGSize, folder: (node: Int, rect: CGRect)?
    ) -> Outcome {
        if delta < 0, !isZoomed {
            outwardAtRest += -delta
            if outwardAtRest >= Self.upThreshold {
                outwardAtRest = 0
                return .goUp
            }
            return .none
        }
        outwardAtRest = 0
        magnify(by: exp(delta * 0.02), at: point, viewport: viewport)

        if delta > 0, let folder {
            let onScreen = transformed(folder.rect)
            let covered = onScreen.intersection(CGRect(origin: .zero, size: viewport))
            if covered.width >= viewport.width * Self.enterCoverage, covered.height >= viewport.height * Self.enterCoverage {
                reset()
                return .enter(folder.node)
            }
        }
        return .none
    }

    /// Keeps the magnified map covering the viewport.
    private mutating func clamp(_ viewport: CGSize) {
        let minX = viewport.width - viewport.width * scale
        let minY = viewport.height - viewport.height * scale
        offset.x = min(0, max(minX, offset.x))
        offset.y = min(0, max(minY, offset.y))
    }
}
