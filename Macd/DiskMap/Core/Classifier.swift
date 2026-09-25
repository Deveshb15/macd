import Foundation

/// What a directory *is* (colour) and whether its space can be had back (hatch).
/// Ported from disktree's `classify.rs`, with macOS locations added.
nonisolated enum Classifier {
    /// The kind a directory name announces on its own, if any.
    static func category(ofName name: String) -> Category? {
        switch name.lowercased() {
        case "src", "code", "projects", "repos", "dev", "work", "workspace", "workspaces", "github.com",
             "gitlab.com", "sites", "development", "developer":
            .code
        case ".codex", ".claude", ".herdr", ".pi", ".cursor", ".aider", ".gemini", ".continue", ".windsurf",
             ".microsandbox", ".omp", ".agents", ".openai", "tries", "worktrees", "experiments", "scratch",
             "playground", ".conductor", ".t3":
            .agentScratch
        case ".cargo", ".rustup", ".local", ".npm", ".pnpm-store", "pnpm", ".bun", ".deno", "go", ".gradle", ".m2",
             ".platformio", "mise", ".mise", ".pyenv", ".nvm", ".gem", "gem", ".rbenv", ".espressif", ".arduino15",
             ".config", ".vscode", ".zig", ".rye", ".conda", "anaconda3", "miniconda3", ".opam", ".ghcup", ".stack",
             ".julia", ".dotnet", ".android", ".sdkman", ".volta", ".yarn", ".java", "homebrew", ".expo",
             ".cocoapods", "coresimulator":
            .toolchain
        case "sync", "dropbox", "nextcloud", "google drive", "onedrive", "pclouddrive", "mega", ".stversions",
             "mobile documents", "cloudstorage", "icloud drive":
            .synced
        case ".git":
            .git
        case "pictures", "photos", "music", "videos", "movies", "steam", "models", ".ollama", ".lmstudio", "games",
             "wineprefix":
            .media
        case "documents", "desktop", "downloads", "books", "notes", "obsidian", "public", "templates":
            .documents
        case ".cache", "cache", "caches", ".ccache", ".sccache", "_cacache", "__pycache__", "node_modules", "trash",
             ".trash", "tmp", ".tmp", "deriveddata":
            .cache
        default:
            mediaPackage(name) ? .media : nil
        }
    }

    private static func mediaPackage(_ name: String) -> Bool {
        ["photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx"]
            .contains((name as NSString).pathExtension.lowercased())
    }

    /// Whether a directory's space can be had back, from its name, its parent's name
    /// and kind, and its siblings.
    static func reclaim(
        ofName name: String, parentName: String, parent: Category, hasSibling: (String) -> Bool
    ) -> Reclaim? {
        let lower = name.lowercased()
        let parentLower = parentName.lowercased()
        switch (parentLower, lower) {
        case ("library", "caches"), ("xcode", "deriveddata"): return lower == "caches" ? .regenerable : .buildOutput
        case ("xcode", let device) where device.hasSuffix(" devicesupport"): return .regenerable
        default: break
        }
        switch lower {
        case ".cache", "cache", "caches", ".ccache", ".sccache", "_cacache": return .regenerable
        case ".stversions": return .syncHistory
        case ".pnpm-store", "pnpm": return .packageStore
        case "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".next", ".turbo", ".parcel-cache":
            return .buildOutput
        case "target" where hasSibling("Cargo.toml"): return .buildOutput
        case "node_modules" where hasSibling("package.json"): return .reinstallable
        case "layers" where parent == .agentScratch: return .sandboxLayers
        case "snapshots" where parent == .agentScratch: return .snapshots
        case "trash", ".trash": return .trash
        case "tmp", ".tmp": return .temporary
        default: return nil
        }
    }

    /// A git object store by its shape: `objects`, `refs`, and `HEAD`.
    static func isGitStore(_ tree: DiskTree, _ id: Int) -> Bool {
        guard tree.isDirectory(id) else { return false }
        let names = Set(tree.children(of: id).map { tree.names[$0] })
        return names.isSuperset(of: ["objects", "refs", "HEAD"])
    }

    /// Assigns a category and reclaim reason to every node. Parents come before children
    /// in the tree's ID order, so one forward pass sees each parent's result first.
    static func classify(_ tree: DiskTree) {
        tree.category[DiskTree.root] = .other
        tree.reclaim[DiskTree.root] = nil
        for id in 1..<tree.count {
            let up = tree.parentOf(id)!
            let parentCategory = tree.category[up]
            let isDirectory = tree.kind[id] == .directory || tree.kind[id] == .unreadable
            let name = tree.names[id]

            var category = parentCategory
            if isDirectory {
                if let own = self.category(ofName: name) {
                    category = own
                } else if isGitStore(tree, id) {
                    category = .git
                } else if up == DiskTree.root, let dominant = dominantChildCategory(tree, id) {
                    category = dominant
                }
            }
            tree.category[id] = category

            var reclaim = tree.reclaim[up]
            if reclaim == nil, isDirectory {
                let siblings = Set(tree.children(of: up).map { tree.names[$0] })
                reclaim = self.reclaim(
                    ofName: name, parentName: tree.names[up], parent: parentCategory,
                    hasSibling: { siblings.contains($0) }
                )
            }
            tree.reclaim[id] = reclaim
        }
    }

    /// The kind of an unknown top-level directory from what fills it: the first
    /// recognisable name down its largest children, a few levels deep.
    private static func dominantChildCategory(_ tree: DiskTree, _ id: Int) -> Category? {
        var node = id
        for _ in 0..<3 {
            let directories = tree.sortedChildren(of: node, by: .allocated).filter { tree.isDirectory($0) }
            for child in directories {
                if let category = category(ofName: tree.names[child]) { return category }
                if isGitStore(tree, child) { return .git }
            }
            guard let largest = directories.first else { return nil }
            node = largest
        }
        return nil
    }
}
