import SwiftUI

@main
struct MacdApp: App {
    var body: some Scene {
        MenuBarExtra("mac'd", systemImage: "gauge.with.dots.needle.33percent") {
            Text("mac'd")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
