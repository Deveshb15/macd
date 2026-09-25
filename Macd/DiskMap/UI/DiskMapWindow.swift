import SwiftUI

/// The disktree-style disk map: top bar, treemap, and side panel.
struct DiskMapWindow: View {
    @Bindable var model: DiskMapModel
    @AppStorage("diskMapPrivacyNoticeSeen") private var privacyNoticeSeen = false
    @State private var zoom = ZoomController()
    @State private var hovered: Int?
    @State private var showingHelp = false
    @FocusState private var filterFocused: Bool
    @FocusState private var mapFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model, filterFocused: $filterFocused)
                .background(Palette.panel)
            Divider()
            HStack(spacing: 0) {
                content
                Divider()
                SidePanel(model: model, hovered: hovered)
            }
            Divider()
            KeyHints(showingHelp: $showingHelp)
        }
        .frame(minWidth: 1100, minHeight: 700)
        .background(Palette.background)
        .preferredColorScheme(.dark)
        .onAppear {
            if privacyNoticeSeen, model.phase == .idle { model.startScan() }
        }
        .sheet(isPresented: Binding(get: { !privacyNoticeSeen }, set: { _ in })) {
            PrivacyNotice {
                privacyNoticeSeen = true
                if model.phase == .idle { model.startScan() }
            }
        }
        .sheet(isPresented: Binding(get: { model.review != .hidden }, set: { if !$0 { model.closeReview() } })) {
            ReviewSheet(model: model)
        }
        .sheet(isPresented: $showingHelp) { HelpSheet() }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        case .scanning where model.tree == nil:
            ScanProgressView(model: model)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't scan", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.rescan() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            TreemapCanvas(model: model, zoom: $zoom, hovered: $hovered)
                .overlay(alignment: .top) {
                    if model.phase == .scanning { ScanBanner(model: model) }
                }
                .focusable()
                .focusEffectDisabled()
                .focused($mapFocused)
                .onKeyPress(phases: .down) { press in handle(press) }
                .onAppear { mapFocused = true }
                .onChange(of: model.viewRoot) { zoom.reset() }
        }
    }

    // MARK: Keys

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard !filterFocused, let action = KeyMap.action(for: keyName(press)) else { return .ignored }
        let target = hovered ?? model.selection
        switch action {
        case .toggleMark: model.toggleMark(target)
        case .open:
            if let target { model.enter(target) }
        case .goUp: model.goUp()
        case .previous: model.stepSelection(by: -1)
        case .next, .nextLargest: model.stepSelection(by: 1)
        case .fewerLevels: model.setDepth(model.depth - 1)
        case .moreLevels: model.setDepth(model.depth + 1)
        case .focusFilter: filterFocused = true
        case .review: model.openReview()
        case .cycleMode:
            let modes = DiskMapModel.Mode.allCases
            model.mode = modes[(modes.firstIndex(of: model.mode)! + 1) % modes.count]
        case .toggleApparent: model.apparentSize.toggle()
        case .toggleHidden: model.setIncludeHidden(!model.includeHidden)
        case .rescan: model.rescan()
        case .wholeDisk: model.scanWholeDisk()
        case .zoomIn: zoom.magnify(by: 1.5, at: center, viewport: canvasSize)
        case .zoomOut: zoom.magnify(by: 1 / 1.5, at: center, viewport: canvasSize)
        case .resetZoom: zoom.reset()
        case .help: showingHelp = true
        }
        if [.previous, .next, .nextLargest].contains(action) { hovered = nil }
        return .handled
    }

    private var canvasSize: CGSize { CGSize(width: 800, height: 600) }
    private var center: CGPoint { CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2) }

    private func keyName(_ press: KeyPress) -> String {
        switch press.key {
        case .space: "space"
        case .return: "return"
        case .delete, .deleteForward: "delete"
        case .escape: "escape"
        case .tab: "tab"
        case .leftArrow: "left"
        case .rightArrow: "right"
        case .upArrow: "up"
        case .downArrow: "down"
        default: press.characters
        }
    }
}

private struct ScanProgressView: View {
    let model: DiskMapModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Measuring \(model.scanRoot == model.home ? "your home folder" : model.scanRoot)…")
                    .font(.headline)
                Text(counters).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var counters: String {
        let progress = model.progress
        let entries = progress.entries.load(ordering: .relaxed)
        let bytes = progress.bytes.load(ordering: .relaxed)
        let unreadable = progress.unreadable.load(ordering: .relaxed)
        var text = "\(entries.formatted()) items · \(Formatters.bytes(bytes))"
        if unreadable > 0 { text += " · \(unreadable) unreadable" }
        return text
    }
}

private struct ScanBanner: View {
    let model: DiskMapModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Rescanning · \(model.progress.entries.load(ordering: .relaxed).formatted()) items")
                    .monospacedDigit()
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(8)
        }
    }
}

private struct KeyHints: View {
    @Binding var showingHelp: Bool

    var body: some View {
        HStack(spacing: 14) {
            hint("space", "mark")
            hint("return", "open")
            hint("⌫", "up")
            hint("c", "review")
            hint("/", "filter")
            hint("[ ]", "depth")
            hint("t", "mode")
            hint("r", "rescan")
            Spacer()
            Button("? all keys") { showingHelp = true }.buttonStyle(.borderless)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Palette.panel)
    }

    private func hint(_ key: String, _ does: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.5)))
            Text(does)
        }
    }
}

private struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keys").font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                ForEach(KeyMap.help, id: \.keys) { row in
                    GridRow {
                        Text(row.keys).monospaced()
                        Text(row.does).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
