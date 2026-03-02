import Foundation

enum Fmt {
    static func uptime(_ seconds: Double?) -> String {
        guard let sec = seconds, sec > 0 else { return "—" }
        let d = Int(sec) / 86400
        let h = Int(sec) % 86400 / 3600
        let m = Int(sec) % 3600 / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func bps(_ value: Double?) -> String {
        guard let v = value, v > 0 else { return "—" }
        if v >= 1_000_000 { return String(format: "%.1f Mbps", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.1f kbps", v / 1_000) }
        return String(format: "%.0f bps", v)
    }

    static func pct(_ value: Double?) -> String {
        guard let v = value else { return "—" }
        return String(format: "%.1f%%", v)
    }

    static func load(_ value: Double?) -> String {
        guard let v = value else { return "—" }
        return String(format: "%.2f", v)
    }

    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt
    }()

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}
