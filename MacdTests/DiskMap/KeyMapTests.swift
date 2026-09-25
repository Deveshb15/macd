import XCTest
@testable import Macd

@MainActor
final class KeyMapTests: XCTestCase {
    func testDocumentedKeys() {
        let expected: [String: KeyMap.Action] = [
            "space": .toggleMark, "x": .toggleMark, "return": .open, "delete": .goUp, "escape": .goUp,
            "left": .previous, "up": .previous, "right": .next, "down": .next, "tab": .nextLargest,
            "[": .fewerLevels, "]": .moreLevels, "/": .focusFilter, "c": .review, "t": .cycleMode,
            "d": .toggleApparent, "i": .toggleHidden, "r": .rescan, "g": .wholeDisk,
            "=": .zoomIn, "-": .zoomOut, "0": .resetZoom, "?": .help,
        ]
        for (key, action) in expected {
            XCTAssertEqual(KeyMap.action(for: key), action, key)
        }
    }

    func testUnknownKeysDoNothing() {
        XCTAssertNil(KeyMap.action(for: "q"))
        XCTAssertNil(KeyMap.action(for: "z"))
    }
}

@MainActor
final class ZoomControllerTests: XCTestCase {
    private let viewport = CGSize(width: 1000, height: 600)

    func testMagnifyKeepsPointFixed() {
        var zoom = ZoomController()
        let point = CGPoint(x: 300, y: 200)
        let before = zoom.untransformed(point)
        zoom.magnify(by: 3, at: point, viewport: viewport)
        let after = zoom.untransformed(point)
        XCTAssertEqual(before.x, after.x, accuracy: 0.001)
        XCTAssertEqual(before.y, after.y, accuracy: 0.001)
        XCTAssertEqual(zoom.scale, 3)
    }

    func testScaleIsClamped() {
        var zoom = ZoomController()
        zoom.magnify(by: 0.1, at: .zero, viewport: viewport)
        XCTAssertEqual(zoom.scale, 1)
        zoom.magnify(by: 1000, at: .zero, viewport: viewport)
        XCTAssertEqual(zoom.scale, ZoomController.maxScale)
    }

    func testZoomingIntoAFolderEntersItOnce() {
        var zoom = ZoomController()
        let folder = (node: 7, rect: CGRect(x: 400, y: 200, width: 200, height: 120))
        let point = CGPoint(x: 500, y: 260)
        var entered: [Int] = []
        for _ in 0..<200 {
            if case .enter(let node) = zoom.zoom(delta: 10, at: point, viewport: viewport, folder: folder) {
                entered.append(node)
                break
            }
        }
        XCTAssertEqual(entered, [7])
        XCTAssertFalse(zoom.isZoomed, "entering resets the transform")
    }

    func testOutwardScrollAtRestGoesUp() {
        var zoom = ZoomController()
        XCTAssertEqual(zoom.zoom(delta: -10, at: .zero, viewport: viewport, folder: nil), .none)
        XCTAssertEqual(zoom.zoom(delta: -10, at: .zero, viewport: viewport, folder: nil), .none)
        XCTAssertEqual(zoom.zoom(delta: -10, at: .zero, viewport: viewport, folder: nil), .goUp)
    }
}
