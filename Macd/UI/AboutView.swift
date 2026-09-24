import SwiftUI

struct AboutView: View {
    let moleVersion: String?

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("mac'd \(appVersion)")
                .font(.headline)
            Text("Cleaning is powered by Mole \(moleVersion ?? "(missing)") by tw93, bundled as a separate program under the GNU GPL v3.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Link("Mole source code", destination: URL(string: "https://github.com/tw93/Mole")!)
                Link("GPL v3 license", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
            }
            .font(.callout)
        }
    }
}
