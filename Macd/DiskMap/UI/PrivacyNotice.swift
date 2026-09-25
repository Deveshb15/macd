import SwiftUI

/// Shown once before the first scan, so macOS's permission prompts aren't a surprise.
struct PrivacyNotice: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Before mac'd measures your disk", systemImage: "lock.shield")
                .font(.title3.weight(.semibold))
            Text("mac'd reads the size of every file in your home folder. Nothing leaves your Mac, and nothing is changed until you review and confirm.")
            VStack(alignment: .leading, spacing: 8) {
                Label("macOS will ask to allow access to Desktop, Documents, and Downloads. Allow them so their sizes are included.", systemImage: "folder")
                Label("Some folders, like Mail and Messages, need Full Disk Access. Without it they show as unreadable.", systemImage: "externaldrive.badge.questionmark")
                Label("Files that live only in iCloud are never downloaded.", systemImage: "icloud")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack {
                Button("Full Disk Access Settings") {
                    NSWorkspace.shared.open(DiskMapModel.fullDiskAccessURL)
                }
                .buttonStyle(SecondaryGlassButtonStyle())
                .fixedSize()
                Spacer()
                Button(action: onContinue) {
                    Label("Start Scan", systemImage: "sparkle.magnifyingglass").frame(width: 130)
                }
                .buttonStyle(PrimaryGlassButtonStyle())
                .fixedSize()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
