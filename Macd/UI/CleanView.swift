import SwiftUI

/// The Free up space flow: preview, confirm, progress, and a result that counts up.
struct CleanView: View {
    @Bindable var flow: CleanFlow
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch flow.state {
            case .idle:
                EmptyView()
            case .previewing:
                working(title: "Looking for things to clean…", symbol: "sparkle.magnifyingglass", actionTitle: "Cancel")
            case .ready(let preview):
                ready(preview)
            case .empty:
                message(symbol: "sparkles", tint: .green, title: "Nothing to clean", detail: "Your Mac is already tidy.")
            case .cleaning:
                working(title: "Cleaning…", symbol: "wand.and.stars", actionTitle: "Stop")
            case .done(let result):
                done(result)
            case .failed(let reason):
                message(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "Something went wrong", detail: reason)
            }
        }
    }

    private func ready(_ preview: CleanPreview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ready to free").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(Formatters.bytes(preview.totalBytes))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(LinearGradient(colors: [Theme.accent, Theme.accentDeep], startPoint: .leading, endPoint: .trailing))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(preview.categories, id: \.name) { category in
                        CategoryRow(category: category, share: Double(category.totalBytes) / Double(max(preview.totalBytes, 1)))
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 230)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

            if !preview.skipped.isEmpty {
                SkippedList(items: preview.skipped)
            }

            Label("Only caches, logs, and temporary files. Your documents aren't touched.", systemImage: "lock.shield")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Cancel") { flow.cancel(); onClose() }
                    .buttonStyle(SecondaryGlassButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    flow.confirmClean()
                } label: {
                    Label("Clean \(Formatters.bytes(preview.totalBytes))", systemImage: "sparkles")
                }
                .buttonStyle(PrimaryGlassButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func done(_ result: CleanResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, options: .nonRepeating)
                VStack(alignment: .leading, spacing: 0) {
                    Text(result.wasCancelled ? "Stopped early. Freed" : "Freed")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    CountingBytes(target: result.freedBytes)
                }
            }
            if !result.skipped.isEmpty {
                SkippedList(items: result.skipped)
            }
            Button("Done") { flow.dismiss(); onClose() }
                .buttonStyle(PrimaryGlassButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    private func working(title: String, symbol: String, actionTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.pulse, options: .repeating)
                Text(title).font(.system(size: 14, weight: .medium))
            }
            ShimmerBar()
            Text(flow.progressLine ?? " ")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack {
                Spacer()
                Button(actionTitle) { flow.cancel() }
                    .buttonStyle(SecondaryGlassButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func message(symbol: String, tint: Color, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("OK") { flow.dismiss(); onClose() }
                .buttonStyle(SecondaryGlassButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// Counts up to the freed amount once, for a small moment of delight.
private struct CountingBytes: View {
    let target: Int64
    @State private var shown: Double = 0

    var body: some View {
        CountingText(value: shown)
            .onAppear {
                withAnimation(.easeOut(duration: 1.1)) { shown = Double(target) }
            }
    }
}

private struct CountingText: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(Formatters.bytes(Int64(value)))
            .font(.system(size: 30, weight: .semibold, design: .rounded))
            .monospacedDigit()
    }
}

/// An indeterminate progress bar with a moving warm highlight.
private struct ShimmerBar: View {
    @State private var phase: CGFloat = -0.4

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(.primary.opacity(0.08))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.accent.opacity(0), Theme.accent, Theme.accentDeep.opacity(0)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geometry.size.width * 0.4)
                        .offset(x: geometry.size.width * phase)
                }
                .clipShape(Capsule())
        }
        .frame(height: 5)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}

private struct CategoryRow: View {
    let category: CleanCategory
    let share: Double
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(Theme.spring) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(category.name).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Capsule()
                        .fill(Theme.accent.opacity(0.8))
                        .frame(width: max(3, 44 * share), height: 4)
                    Text(Formatters.bytes(category.totalBytes))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(category.items, id: \.label) { item in
                        HStack {
                            Text(item.label).lineLimit(1)
                            Spacer()
                            Text(item.bytes.map(Formatters.bytes) ?? "—").monospacedDigit()
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 23)
                .padding(.trailing, 6)
                .padding(.bottom, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct SkippedList: View {
    let items: [SkippedItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Skipped")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(items, id: \.label) { item in
                HStack(alignment: .firstTextBaseline) {
                    Text(item.label).lineLimit(1)
                    Spacer()
                    Text(item.reason)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
                .font(.system(size: 11))
            }
        }
    }
}
