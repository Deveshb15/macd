import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        @Bindable var settings = model.settings

        Form {
            Section("Menu bar") {
                Toggle("CPU temperature", isOn: $settings.showTemperature)
                Toggle("Memory used", isOn: $settings.showMemory)
                Toggle("Disk free", isOn: $settings.showDisk)
            }

            Section("Low-space alert") {
                Toggle("Notify me when disk space runs low", isOn: Binding(
                    get: { settings.lowSpaceAlertsEnabled },
                    set: { model.setLowSpaceAlerts($0) }
                ))
                Stepper(value: $settings.lowSpaceThresholdGB, in: 1...500, step: 5) {
                    Text("When less than \(settings.lowSpaceThresholdGB) GB is free")
                }
                .disabled(!settings.lowSpaceAlertsEnabled)
                if settings.lowSpaceAlertsEnabled, !model.notifications.isAuthorized {
                    Text("Notifications are turned off for mac'd in System Settings › Notifications.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("General") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LaunchAtLogin.setEnabled(enabled)
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("About") {
                AboutView(moleVersion: model.moleVersion)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .task { await model.notifications.refreshAuthorization() }
    }
}
