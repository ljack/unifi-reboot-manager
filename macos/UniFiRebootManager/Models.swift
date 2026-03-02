import Foundation

// MARK: - Device State Machine

enum DeviceState: String, Sendable, CaseIterable {
    case online = "ONLINE"
    case rebootSent = "REBOOT_SENT"
    case goingOffline = "GOING_OFFLINE"
    case offline = "OFFLINE"
    case comingBack = "COMING_BACK"
    case rebootFailed = "REBOOT_FAILED"
    case stuck = "STUCK"

    var displayName: String {
        rawValue.replacingOccurrences(of: "_", with: " ")
    }

    var isTransitioning: Bool {
        switch self {
        case .rebootSent, .goingOffline, .offline, .comingBack: true
        default: false
        }
    }

    var sortOrder: Int {
        switch self {
        case .online: 0
        case .rebootSent: 1
        case .goingOffline: 2
        case .comingBack: 3
        case .offline: 4
        case .rebootFailed: 5
        case .stuck: 6
        }
    }
}

// MARK: - Device Type

enum DeviceType: String, Sendable {
    case gateway, ap, `switch`, hybrid, unknown

    var badge: String {
        switch self {
        case .gateway: "GW"
        case .ap: "AP"
        case .switch: "SW"
        case .hybrid: "AP/SW"
        case .unknown: "??"
        }
    }

    var sortOrder: Int {
        switch self {
        case .gateway: 0
        case .ap: 1
        case .hybrid: 2
        case .switch: 3
        case .unknown: 4
        }
    }
}

// MARK: - Sort Option

enum SortOption: String, CaseIterable, Sendable {
    case name = "Name"
    case ip = "IP Address"
    case status = "Status"
    case type = "Type"
    case model = "Model"
    case uptime = "Uptime"
    case cpu = "CPU Usage"
    case memory = "Memory Usage"
}

// MARK: - API Response Models

struct UniFiDeviceResponse: Decodable, Sendable {
    let data: [UniFiDevice]
}

struct UniFiDevice: Decodable, Sendable {
    let id: String
    let name: String?
    let model: String?
    let ipAddress: String?
    let macAddress: String?
    let state: String?
    let firmwareVersion: String?
    let features: [String]?

    var displayName: String { name ?? "Unknown" }
}

struct DeviceStats: Decodable, Sendable {
    let uptimeSec: Double?
    let cpuUtilizationPct: Double?
    let memoryUtilizationPct: Double?
    let loadAverage1Min: Double?
    let loadAverage5Min: Double?
    let loadAverage15Min: Double?
    let lastHeartbeatAt: String?
    let uplink: UplinkStats?
    let interfaces: InterfaceStats?

    struct UplinkStats: Decodable, Sendable {
        let txRateBps: Double?
        let rxRateBps: Double?
    }

    struct InterfaceStats: Decodable, Sendable {
        let radios: [RadioStats]?
    }

    struct RadioStats: Decodable, Sendable {
        let frequencyGHz: Double?
        let txRetriesPct: Double?
    }
}

// MARK: - Internal Tracking State

struct DeviceEntry: Identifiable, Sendable {
    let id: String
    var state: DeviceState
    var device: UniFiDevice
    var type: DeviceType
    var isGateway: Bool
    var history: [StateHistoryEntry]
    var stateChangedAt: Date
    var lastPing: PingResult?
    var stats: DeviceStats?
}

struct StateHistoryEntry: Identifiable, Sendable {
    let id = UUID()
    let state: DeviceState
    let time: Date
}

struct PingResult: Sendable {
    let alive: Bool
    let time: Date
}

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let message: String
    let level: LogLevel
    let time: Date

    enum LogLevel: String, Sendable {
        case info, success, warn, error
    }
}
