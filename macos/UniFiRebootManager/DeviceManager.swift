import Foundation
import SwiftUI

@MainActor
@Observable
final class DeviceManager {
    // MARK: - Public State

    var devices: [String: DeviceEntry] = [:]
    var monitoring = false
    var logEntries: [LogEntry] = []
    var selectedDeviceID: String?
    var sortOption: SortOption = .name
    var isConfigured = false
    var isLoading = false
    var error: String?

    // MARK: - Configuration (persisted)

    var host: String = UserDefaults.standard.string(forKey: "unifi_host") ?? "" {
        didSet { UserDefaults.standard.set(host, forKey: "unifi_host") }
    }
    var apiKey: String = {
        // Migrate from UserDefaults to Keychain on first launch
        if let legacy = UserDefaults.standard.string(forKey: "unifi_api_key"), !legacy.isEmpty {
            KeychainHelper.save(key: "unifi_api_key", value: legacy)
            UserDefaults.standard.removeObject(forKey: "unifi_api_key")
            return legacy
        }
        return KeychainHelper.load(key: "unifi_api_key") ?? ""
    }() {
        didSet { KeychainHelper.save(key: "unifi_api_key", value: apiKey) }
    }
    var siteID: String = UserDefaults.standard.string(forKey: "unifi_site_id") ?? "" {
        didSet { UserDefaults.standard.set(siteID, forKey: "unifi_site_id") }
    }

    // MARK: - Timing Constants

    private let pingInterval: TimeInterval = 2
    private let pollInterval: TimeInterval = 5
    private let stuckTimeout: TimeInterval = 300
    private let statsRefreshInterval: TimeInterval = 10

    // MARK: - Internal

    private let api = UniFiAPI()
    private var pingTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var stuckTask: Task<Void, Never>?
    private var idleStatsTask: Task<Void, Never>?

    // MARK: - Computed Properties

    var sortedDevices: [DeviceEntry] {
        Array(devices.values).sorted { a, b in
            switch sortOption {
            case .name:
                if a.isGateway != b.isGateway { return a.isGateway }
                return a.device.displayName.localizedStandardCompare(b.device.displayName) == .orderedAscending
            case .ip:
                return ipToNum(a.device.ipAddress) < ipToNum(b.device.ipAddress)
            case .status:
                if a.state.sortOrder != b.state.sortOrder { return a.state.sortOrder < b.state.sortOrder }
                return a.device.displayName.localizedStandardCompare(b.device.displayName) == .orderedAscending
            case .type:
                if a.type.sortOrder != b.type.sortOrder { return a.type.sortOrder < b.type.sortOrder }
                return a.device.displayName.localizedStandardCompare(b.device.displayName) == .orderedAscending
            case .model:
                let cmp = (a.device.model ?? "").localizedStandardCompare(b.device.model ?? "")
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return a.device.displayName.localizedStandardCompare(b.device.displayName) == .orderedAscending
            case .uptime:
                return (a.stats?.uptimeSec ?? 0) > (b.stats?.uptimeSec ?? 0)
            case .cpu:
                return (a.stats?.cpuUtilizationPct ?? 0) > (b.stats?.cpuUtilizationPct ?? 0)
            case .memory:
                return (a.stats?.memoryUtilizationPct ?? 0) > (b.stats?.memoryUtilizationPct ?? 0)
            }
        }
    }

    var onlineCount: Int { devices.values.filter { $0.state == .online }.count }
    var totalCount: Int { devices.count }
    var hasTransitioning: Bool { devices.values.contains { $0.state.isTransitioning } }

    // MARK: - Initialization

    func loadDevices() async {
        // Cancel any active monitoring/stats tasks before reloading
        if monitoring {
            monitoring = false
            pingTask?.cancel()
            pollTask?.cancel()
            stuckTask?.cancel()
            pingTask = nil
            pollTask = nil
            stuckTask = nil
        }
        idleStatsTask?.cancel()
        idleStatsTask = nil

        isLoading = true
        error = nil

        await api.configure(host: host, apiKey: apiKey, siteID: siteID)

        do {
            let apiDevices = try await api.fetchDevices()
            devices.removeAll()

            for d in apiDevices {
                let type = Self.detectType(d)
                let state: DeviceState = d.state == "ONLINE" ? .online : .offline
                devices[d.id] = DeviceEntry(
                    id: d.id,
                    state: state,
                    device: d,
                    type: type,
                    isGateway: type == .gateway,
                    history: [StateHistoryEntry(state: state, time: .now)],
                    stateChangedAt: .now,
                    lastPing: nil,
                    stats: nil
                )
            }

            isConfigured = true
            await fetchAllStats()
            log("Loaded \(devices.count) devices", level: .success)
            startIdleStatsRefresh()
        } catch {
            self.error = error.localizedDescription
            log("Failed to load devices: \(error.localizedDescription)", level: .error)
        }

        isLoading = false
    }

    // MARK: - State Machine

    private func setState(_ id: String, _ newState: DeviceState) {
        guard var entry = devices[id], entry.state != newState else { return }
        entry.state = newState
        entry.stateChangedAt = .now
        entry.history.append(StateHistoryEntry(state: newState, time: .now))
        devices[id] = entry

        let level: LogEntry.LogLevel = switch newState {
        case .online: .success
        case .rebootFailed, .stuck: .error
        default: .info
        }
        log("\(entry.device.displayName): \(newState.displayName)", level: level)
    }

    private func onPing(_ id: String, alive: Bool) {
        guard var entry = devices[id] else { return }
        entry.lastPing = PingResult(alive: alive, time: .now)
        devices[id] = entry

        switch entry.state {
        case .rebootSent where !alive: setState(id, .goingOffline)
        case .goingOffline where !alive: setState(id, .offline)
        case .offline where alive: setState(id, .comingBack)
        default: break
        }
    }

    private func onApiState(_ id: String, apiState: String, deviceData: UniFiDevice) {
        guard var entry = devices[id] else { return }
        entry.device = deviceData
        devices[id] = entry

        if apiState == "ONLINE" && [.comingBack, .rebootSent, .goingOffline].contains(entry.state) {
            setState(id, .online)
        }
        checkComplete()
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        log("Monitoring started")

        // Ping every 2s
        pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pingInterval))
                guard !Task.isCancelled else { break }
                await pingAllDevices()
            }
        }

        // API poll every 5s
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pollInterval))
                guard !Task.isCancelled else { break }
                await pollDevices()
            }
        }

        // Stuck detection every 10s
        stuckTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { break }
                checkStuck()
            }
        }
    }

    private func stopMonitoring() {
        monitoring = false
        pingTask?.cancel()
        pollTask?.cancel()
        stuckTask?.cancel()
        pingTask = nil
        pollTask = nil
        stuckTask = nil
        log("All devices settled — monitoring stopped", level: .success)
    }

    private func checkComplete() {
        if !hasTransitioning && monitoring {
            stopMonitoring()
        }
    }

    private func checkStuck() {
        let now = Date.now
        for (id, entry) in devices {
            if entry.state.isTransitioning &&
                now.timeIntervalSince(entry.stateChangedAt) > stuckTimeout
            {
                setState(id, .stuck)
            }
        }
    }

    // MARK: - Ping

    private func pingAllDevices() async {
        let targets = devices.values.compactMap { entry -> (String, String)? in
            guard let ip = entry.device.ipAddress else { return nil }
            return (entry.id, ip)
        }

        let results: [(String, Bool)] = await withTaskGroup(
            of: (String, Bool).self,
            returning: [(String, Bool)].self
        ) { group in
            for (id, ip) in targets {
                group.addTask {
                    let alive = await Self.ping(ip)
                    return (id, alive)
                }
            }
            var collected: [(String, Bool)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        for (id, alive) in results {
            onPing(id, alive: alive)
        }
    }

    nonisolated static func ping(_ ip: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/ping")
            process.arguments = ["-c", "1", "-W", "1000", ip]
            process.standardOutput = nil
            process.standardError = nil

            process.terminationHandler = { @Sendable proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    // MARK: - API Polling

    private func pollDevices() async {
        do {
            let apiDevices = try await api.fetchDevices()
            for d in apiDevices {
                onApiState(d.id, apiState: d.state ?? "", deviceData: d)
            }
        } catch {
            log("API poll failed: \(error.localizedDescription)", level: .warn)
        }
        await fetchAllStats()
    }

    // MARK: - Statistics

    private func fetchAllStats() async {
        let ids = Array(devices.keys)
        let results: [(String, DeviceStats?)] = await withTaskGroup(
            of: (String, DeviceStats?).self,
            returning: [(String, DeviceStats?)].self
        ) { [api] group in
            for id in ids {
                group.addTask {
                    let stats = try? await api.fetchStats(deviceID: id)
                    return (id, stats)
                }
            }
            var collected: [(String, DeviceStats?)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        for (id, stats) in results {
            if let stats, var entry = devices[id] {
                entry.stats = stats
                devices[id] = entry
            }
        }
    }

    private func startIdleStatsRefresh() {
        idleStatsTask?.cancel()
        idleStatsTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(statsRefreshInterval))
                guard !Task.isCancelled else { break }
                if !monitoring {
                    await fetchAllStats()
                }
            }
        }
    }

    // MARK: - Reboot Actions

    func rebootAll() async {
        log("Reboot All initiated")
        let onlineIDs = devices.filter { $0.value.state == .online }.map { $0.key }
        log("Sending restart to \(onlineIDs.count) online devices")

        for id in onlineIDs {
            setState(id, .rebootSent)
        }

        let results: [(String, Result<(Bool, Int), Error>)] = await withTaskGroup(
            of: (String, Result<(Bool, Int), Error>).self,
            returning: [(String, Result<(Bool, Int), Error>)].self
        ) { [api] group in
            for id in onlineIDs {
                group.addTask {
                    do {
                        let r = try await api.rebootDevice(id: id)
                        return (id, .success((r.ok, r.status)))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            var collected: [(String, Result<(Bool, Int), Error>)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        for (id, result) in results {
            let name = devices[id]?.device.displayName ?? "Unknown"
            switch result {
            case .success((let ok, let status)):
                if !ok {
                    setState(id, .rebootFailed)
                    log("\(name): failed (HTTP \(status))", level: .error)
                } else {
                    log("\(name): restart sent")
                }
            case .failure(let error):
                setState(id, .rebootFailed)
                log("\(name): error — \(error.localizedDescription)", level: .error)
            }
        }

        startMonitoring()
    }

    func rebootOne(_ id: String) async {
        guard let entry = devices[id] else { return }
        setState(id, .rebootSent)
        log("Rebooting \(entry.device.displayName)")

        do {
            let result = try await api.rebootDevice(id: id)
            if !result.ok {
                setState(id, .rebootFailed)
                log("\(entry.device.displayName): failed (HTTP \(result.status))", level: .error)
            } else {
                log("\(entry.device.displayName): restart sent")
                startMonitoring()
            }
        } catch {
            setState(id, .rebootFailed)
            log("\(entry.device.displayName): error — \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - Logging

    func log(_ message: String, level: LogEntry.LogLevel = .info) {
        let entry = LogEntry(message: message, level: level, time: .now)
        logEntries.append(entry)
        if logEntries.count > 200 {
            logEntries.removeFirst(logEntries.count - 200)
        }
    }

    func clearLog() { logEntries.removeAll() }

    // MARK: - Helpers

    static func detectType(_ d: UniFiDevice) -> DeviceType {
        if let model = d.model, model.contains("Dream Machine") { return .gateway }
        let features = d.features ?? []
        let hasAP = features.contains("accessPoint")
        let hasSW = features.contains("switching")
        if hasAP && hasSW { return .hybrid }
        if hasAP { return .ap }
        if hasSW { return .switch }
        return .unknown
    }

    private func ipToNum(_ ip: String?) -> UInt32 {
        guard let ip else { return 0 }
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return 0 }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }
}
