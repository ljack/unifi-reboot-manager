import SwiftUI

// GitHub Dark color palette matching the web UI
enum Theme {
    // Base
    static let bg = Color(hex: 0x0d1117)
    static let surface = Color(hex: 0x161b22)
    static let surface2 = Color(hex: 0x1c2333)
    static let border = Color(hex: 0x30363d)
    static let text = Color(hex: 0xe6edf3)
    static let muted = Color(hex: 0x8b949e)
    static let dim = Color(hex: 0x6e7681)

    // Semantic
    static let green = Color(hex: 0x3fb950)
    static let amber = Color(hex: 0xd29922)
    static let orange = Color(hex: 0xdb6d28)
    static let red = Color(hex: 0xf85149)
    static let blue = Color(hex: 0x58a6ff)
    static let purple = Color(hex: 0xbc8cff)
    static let cyan = Color(hex: 0x56d4dd)

    static func stateColor(_ state: DeviceState) -> Color {
        switch state {
        case .online: green
        case .rebootSent: amber
        case .goingOffline: orange
        case .offline, .rebootFailed, .stuck: red
        case .comingBack: blue
        }
    }

    static func typeColor(_ type: DeviceType) -> Color {
        switch type {
        case .gateway: purple
        case .ap: blue
        case .switch: green
        case .hybrid: cyan
        case .unknown: muted
        }
    }

    static func meterColor(_ pct: Double) -> Color {
        if pct > 85 { return red }
        if pct > 60 { return amber }
        return green
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
