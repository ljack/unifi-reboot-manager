import SwiftUI

struct ContentView: View {
    @Environment(DeviceManager.self) private var manager
    @State private var showRebootConfirm = false
    @State private var logCollapsed = false

    var body: some View {
        Group {
            if manager.isConfigured && manager.totalCount > 0 {
                mainContent
            } else {
                setupView
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(spacing: 0) {
            headerBar

            HSplitView {
                // Device grid
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 240), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(manager.sortedDevices) { entry in
                            DeviceCardView(entry: entry, isSelected: manager.selectedDeviceID == entry.id)
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        if manager.selectedDeviceID == entry.id {
                                            manager.selectedDeviceID = nil
                                        } else {
                                            manager.selectedDeviceID = entry.id
                                        }
                                    }
                                }
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 180) // Space for log panel
                }
                .frame(minWidth: 400)

                // Detail sidebar
                DetailPanelView()
                    .frame(width: 340)
            }

            // Event log
            EventLogView(collapsed: $logCollapsed)
        }
        .alert("Confirm Reboot All", isPresented: $showRebootConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reboot All", role: .destructive) {
                Task { await manager.rebootAll() }
            }
        } message: {
            Text("This will restart all online devices simultaneously, including the gateway. Network connectivity will be temporarily disrupted.")
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text("UniFi Reboot Manager")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)

            Spacer()

            // Progress indicator
            Text("\(manager.onlineCount)/\(manager.totalCount) online")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(
                    manager.hasTransitioning ? Theme.amber :
                    manager.onlineCount == manager.totalCount ? Theme.green : Theme.muted
                )

            // Sort
            Text("Sort")
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)

            Picker("", selection: Bindable(manager).sortOption) {
                ForEach(SortOption.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .frame(width: 130)
            .labelsHidden()

            // Reboot All button
            Button {
                showRebootConfirm = true
            } label: {
                Text(manager.monitoring ? "Rebooting..." : "Reboot All")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.red)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .background(Theme.red.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.red.opacity(0.35), lineWidth: 1))
            .disabled(manager.monitoring)
            .opacity(manager.monitoring ? 0.4 : 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            Divider().overlay(Theme.border)
        }
    }

    // MARK: - Setup View

    private var setupView: some View {
        VStack(spacing: 20) {
            if manager.isLoading {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Loading devices...")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            } else {
                Image(systemName: "network")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.dim)

                Text("Configure UniFi Controller")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.text)

                Text("Enter your UniFi controller details to get started")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)

                SettingsFormView()
                    .frame(width: 400)

                if let error = manager.error {
                    Text(error)
                        .foregroundStyle(Theme.red)
                        .font(.system(size: 12))
                        .padding(.horizontal, 20)
                }

                Button {
                    Task { await manager.loadDevices() }
                } label: {
                    Text("Connect")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.bg)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(Theme.blue)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .disabled(manager.host.isEmpty || manager.apiKey.isEmpty || manager.siteID.isEmpty)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
