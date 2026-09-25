import Foundation

/// A kind of data, for colour. Ported from disktree's `classify.rs`.
nonisolated enum Category: UInt8, Sendable, CaseIterable {
    case code, agentScratch, toolchain, synced, git, media, documents, cache, other

    /// The categories the legend lists, in its order.
    static let legend: [Category] = [.code, .agentScratch, .toolchain, .synced, .git, .media, .documents, .cache]

    var label: String {
        switch self {
        case .code: "Code"
        case .agentScratch: "Agent scratch"
        case .toolchain: "Toolchains"
        case .synced: "Synced"
        case .git: "Git"
        case .media: "Media"
        case .documents: "Documents"
        case .cache: "Cache"
        case .other: "Other"
        }
    }
}

/// Why a directory's space can be had back.
nonisolated enum Reclaim: UInt8, Sendable {
    case regenerable, syncHistory, packageStore, buildOutput, reinstallable, sandboxLayers, snapshots, trash, temporary

    var label: String {
        switch self {
        case .regenerable: "regenerable"
        case .syncHistory: "sync history"
        case .packageStore: "package store"
        case .buildOutput: "build output"
        case .reinstallable: "reinstallable"
        case .sandboxLayers: "sandbox layers"
        case .snapshots: "snapshots"
        case .trash: "trash"
        case .temporary: "temporary"
        }
    }
}

nonisolated enum NodeKind: UInt8, Sendable {
    case directory
    case file
    /// Files below the small-file threshold in one folder, summed into one entry. Not a real path.
    case smallFiles
    /// A directory the scan was not allowed to read.
    case unreadable
    /// A directory on another volume, not measured.
    case otherVolume
}

nonisolated struct NodeFlags: OptionSet, Sendable, Hashable {
    let rawValue: UInt8
    /// An app bundle or document package (`.app`, `.photoslibrary`, …).
    static let package = NodeFlags(rawValue: 1 << 0)
    /// Cloud-only: its data lives in iCloud, not on this disk.
    static let dataless = NodeFlags(rawValue: 1 << 1)
    static let hidden = NodeFlags(rawValue: 1 << 2)
    static let symlink = NodeFlags(rawValue: 1 << 3)
}

/// What tiles are sized by.
nonisolated enum SizeMetric: Sendable, Equatable {
    case allocated
    case apparent
    case files
}
