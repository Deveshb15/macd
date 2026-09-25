import Foundation

/// "Worth a look": the biggest things in a scan that could plausibly go.
/// Ported from disktree's `insights.rs`. Findings never nest, so their total is real.
nonisolated enum WorthALook {
    static let day: Int64 = 86_400
    static let staleDays: Int64 = 30
    static let minimumBytes: UInt64 = 64 * 1024 * 1024

    enum Finding: Equatable, Sendable {
        case reclaimable(Reclaim)
        case worktrees(count: Int, oldestDays: Int64)
        case staleExperiments(count: Int)

        var detail: String {
            switch self {
            case .reclaimable(let reason): reason.label
            case .worktrees(let count, let oldest): "\(count) worktree\(count == 1 ? "" : "s") · oldest \(oldest) days"
            case .staleExperiments(let count): "\(count) experiment\(count == 1 ? "" : "s") untouched for 30+ days"
            }
        }
    }

    struct Candidate: Equatable, Sendable {
        let node: Int
        let bytes: UInt64
        let finding: Finding
    }

    static func candidates(in tree: DiskTree, now: Int64, limit: Int = 8) -> [Candidate] {
        var found: [Candidate] = []
        for child in tree.children(of: DiskTree.root) {
            visit(tree, child, now: now, found: &found)
        }
        return Array(found.filter { $0.bytes >= minimumBytes }.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }

    private static func visit(_ tree: DiskTree, _ id: Int, now: Int64, found: inout [Candidate]) {
        guard tree.isDirectory(id) else { return }
        if let reason = tree.reclaim[id] {
            found.append(Candidate(node: id, bytes: tree.allocated[id], finding: .reclaimable(reason)))
            return
        }
        let name = tree.names[id].lowercased()
        let scratch = tree.category[id] == .agentScratch

        if scratch, name == "worktrees" {
            let trees = tree.children(of: id).filter { tree.isDirectory($0) }
            if !trees.isEmpty {
                let oldest = trees.map { tree.newest[$0] }.filter { $0 > 0 }.min() ?? now
                found.append(Candidate(
                    node: id, bytes: tree.allocated[id],
                    finding: .worktrees(count: trees.count, oldestDays: max(0, now - oldest) / day)
                ))
                return
            }
        }

        let experiments = scratch && (name == "tries" || name == "experiments")
        var staleCount = 0
        var staleBytes: UInt64 = 0
        for child in tree.children(of: id) {
            let stale = experiments && tree.isDirectory(child) && tree.newest[child] > 0
                && now - tree.newest[child] > staleDays * day
            if stale {
                staleCount += 1
                staleBytes += tree.allocated[child]
                continue
            }
            visit(tree, child, now: now, found: &found)
        }
        if staleCount > 0 {
            found.append(Candidate(node: id, bytes: staleBytes, finding: .staleExperiments(count: staleCount)))
        }
    }
}
