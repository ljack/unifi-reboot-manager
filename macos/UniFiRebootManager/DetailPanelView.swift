import SwiftUI

struct DetailPanelView: View {
    @Environment(DeviceManager.self) private var manager
    @State private var showRebootConfirm = false

    private static let isoFormatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    private static let isoFormatterNoFrac: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    var body: some View {
        if let id = manager.selectedDeviceID, let entry = manager.devices[id] {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    statusHeader(entry)
                    deviceInfo(entry)
                    if let stats = entry.stats {
                        statisticsSection(stats)
                    }
                    rebootButton(entry)
                    statusHistory(entry)
                }
                .padding(20)
                .alert("Confirm Reboot", isPresented: $showRebootConfirm) {
                    Button("Cancel", role: .cancel) {}
                    Button("Reboot", role: .destructive) {
                        Task { await manager.rebootOne(id) }
                    }
                } message: {
                    Text("This will restart \(entry.device.displayName). The device will be temporarily unavailable.")
                }
            }
            .background(Theme.surface)
        } else {
            VStack {
                Spacer()
                Text("Select a device to view details")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(Theme.surface)
        }
    }

    // MARK: - Status Header

    @ViewBuilder
    private func statusHeader(_ entry: DeviceEntry) -> some View {
        let color = Theme.stateColor(entry.state)

        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(entry.state.displayName)
                .font(.system(size: 10, weight: .bold))
                .kerning(0.5)
                .textCase(.uppercase)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
        .padding(.bottom, 16)

        Text(entry.device.displayName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.text)
            .padding(.bottom, 2)

        Text(entry.device.model ?? "")
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
            .padding(.bottom, 20)
    }

    // MARK: - Device Info

    @ViewBuilder
    private func deviceInfo(_ entry: DeviceEntry) -> some View {
        sectionHeader("Device")

        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            infoRow("IP", entry.device.ipAddress ?? "—")
            infoRow("MAC", entry.device.macAddress ?? "—")
            infoRow("Firmware", entry.device.firmwareVersion ?? "—")
            infoRow("Features", (entry.device.features ?? []).joined(separator: ", ").isEmpty
                ? "—" : (entry.device.features ?? []).joined(separator: ", "))
        }
        .font(.system(size: 12))
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(Theme.dim)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
        }
    }

    // MARK: - Statistics

    @ViewBuilder
    private func statisticsSection(_ stats: DeviceStats) -> some View {
        sectionHeader("Statistics")

        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            // Uptime
            metricCard("Uptime", Fmt.uptime(stats.uptimeSec))

            // Last heartbeat
            if let hb = stats.lastHeartbeatAt {
                metricCard("Last Heartbeat", formatHeartbeat(hb))
            }

            // CPU
            if let cpu = stats.cpuUtilizationPct {
                metricCardWithMeter("CPU", Fmt.pct(cpu), cpu)
            }

            // Memory
            if let mem = stats.memoryUtilizationPct {
                metricCardWithMeter("Memory", Fmt.pct(mem), mem)
            }
        }

        // Load Average (wide)
        if let l1 = stats.loadAverage1Min {
            wideMetric("Load Average") {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(Fmt.load(l1))
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.text)
                        Text(" / \(Fmt.load(stats.loadAverage5Min)) / \(Fmt.load(stats.loadAverage15Min))")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.dim)
                    }
                    Text("1 min / 5 min / 15 min")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.dim)
                }
            }
        }

        // Uplink
        if let uplink = stats.uplink {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                metricCard("Uplink TX", Fmt.bps(uplink.txRateBps))
                metricCard("Uplink RX", Fmt.bps(uplink.rxRateBps))
            }
        }

        // Radio stats
        if let radios = stats.interfaces?.radios, !radios.isEmpty {
            wideMetric("Radio TX Retries") {
                Text(radios.map { r in
                    let freq = r.frequencyGHz.map { String(format: "%.1fGHz", $0) } ?? "?"
                    return "\(freq): \(Fmt.pct(r.txRetriesPct))"
                }.joined(separator: " · "))
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text)
            }
        }

        Spacer().frame(height: 20)
    }

    // MARK: - Reboot Button

    @ViewBuilder
    private func rebootButton(_ entry: DeviceEntry) -> some View {
        Button {
            showRebootConfirm = true
        } label: {
            Text("Reboot This Device")
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.red)
        .background(Theme.red.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.red.opacity(0.35), lineWidth: 1))
        .disabled(entry.state.isTransitioning)
        .opacity(entry.state.isTransitioning ? 0.4 : 1)
        .padding(.bottom, 20)
    }

    // MARK: - Status History

    @ViewBuilder
    private func statusHistory(_ entry: DeviceEntry) -> some View {
        sectionHeader("Status History")

        VStack(spacing: 0) {
            ForEach(entry.history.reversed()) { h in
                HStack(spacing: 10) {
                    Text(Fmt.time(h.time))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .frame(width: 68, alignment: .leading)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(Theme.stateColor(h.state))
                            .frame(width: 6, height: 6)
                        Text(h.state.displayName)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.text)
                    }

                    Spacer()
                }
                .padding(.vertical, 5)
                .overlay(alignment: .top) {
                    if h.id != entry.history.last?.id {
                        Divider().overlay(Theme.border)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.5)
                .textCase(.uppercase)
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)
            Divider().overlay(Theme.border)
        }
        .padding(.bottom, 10)
    }

    private func metricCard(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func metricCardWithMeter(_ label: String, _ value: String, _ pct: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.border)
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.meterColor(pct))
                        .frame(width: geo.size.width * min(pct / 100, 1), height: 4)
                }
            }
            .frame(height: 4)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func wideMetric<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.top, 10)
    }

    private func formatHeartbeat(_ isoString: String) -> String {
        if let date = Self.isoFormatter.date(from: isoString) {
            return Fmt.time(date)
        }
        // Try without fractional seconds
        if let date = Self.isoFormatterNoFrac.date(from: isoString) {
            return Fmt.time(date)
        }
        return isoString
    }
}
