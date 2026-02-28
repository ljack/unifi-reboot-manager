import SwiftUI

struct SettingsView: View {
    @Environment(DeviceManager.self) private var manager

    var body: some View {
        @Bindable var mgr = manager

        Form {
            Section("UniFi Controller") {
                TextField("Host URL", text: $mgr.host, prompt: Text("https://192.168.1.1"))
                    .textFieldStyle(.roundedBorder)

                TextField("API Key", text: $mgr.apiKey, prompt: Text("Your API key"))
                    .textFieldStyle(.roundedBorder)

                TextField("Site ID", text: $mgr.siteID, prompt: Text("Your site ID"))
                    .textFieldStyle(.roundedBorder)
            }

            Section {
                Button("Reconnect") {
                    Task { await manager.loadDevices() }
                }
                .disabled(manager.host.isEmpty || manager.apiKey.isEmpty || manager.siteID.isEmpty)
            }

            if let error = manager.error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 280)
    }
}

// Inline settings form used in the initial setup screen
struct SettingsFormView: View {
    @Environment(DeviceManager.self) private var manager

    var body: some View {
        @Bindable var mgr = manager

        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Host URL")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.muted)
                TextField("", text: $mgr.host, prompt: Text("https://192.168.1.1"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(8)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("API Key")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.muted)
                SecureField("", text: $mgr.apiKey, prompt: Text("Your API key"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(8)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Site ID")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.muted)
                TextField("", text: $mgr.siteID, prompt: Text("Your site ID"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(8)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            }
        }
    }
}
