import Foundation

/// disktree's keys, mapped to disk map actions.
enum KeyMap {
    enum Action: Equatable {
        case toggleMark
        case open
        case goUp
        case previous
        case next
        case nextLargest
        case fewerLevels
        case moreLevels
        case focusFilter
        case review
        case cycleMode
        case toggleApparent
        case toggleHidden
        case rescan
        case wholeDisk
        case zoomIn
        case zoomOut
        case resetZoom
        case help
    }

    /// Named keys the view reports: "space", "return", "delete", "escape", "tab",
    /// "left", "right", "up", "down"; anything else is the typed character.
    static func action(for key: String) -> Action? {
        switch key {
        case "space", "x": .toggleMark
        case "return": .open
        case "delete", "escape": .goUp
        case "left", "up": .previous
        case "right", "down": .next
        case "tab": .nextLargest
        case "[": .fewerLevels
        case "]": .moreLevels
        case "/": .focusFilter
        case "c": .review
        case "t": .cycleMode
        case "d": .toggleApparent
        case "i": .toggleHidden
        case "r": .rescan
        case "g": .wholeDisk
        case "=", "+": .zoomIn
        case "-": .zoomOut
        case "0": .resetZoom
        case "?": .help
        default: nil
        }
    }

    static let help: [(keys: String, does: String)] = [
        ("space / x", "mark or unmark"),
        ("return", "open the folder"),
        ("⌫ / esc", "go up one folder"),
        ("← → ↑ ↓", "previous or next tile"),
        ("tab", "next largest"),
        ("[ ]", "fewer or more levels"),
        ("/", "filter by name"),
        ("c", "review what's marked"),
        ("t", "size, files, or age"),
        ("d", "disk usage or apparent size"),
        ("i", "show or hide hidden files"),
        ("r", "scan again"),
        ("g", "the whole disk"),
        ("= - 0", "magnify, shrink, reset"),
        ("scroll / pinch", "zoom toward a folder, then go in"),
        ("⌃-click", "mark without selecting"),
    ]
}
