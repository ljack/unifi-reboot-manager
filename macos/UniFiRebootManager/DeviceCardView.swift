import SwiftUI

struct DeviceCardView: View {
    let entry: DeviceEntry
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top row: type badge + state badge
            HStack {
                typeBadge
                Spacer()
                stateBadge
            }
            .padding(.bottom, 10)

            // Device name
            Text(entry.device.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.bottom, 3)

            // Model + IP
            Text(metaText)
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .truncationMode(.tail)

            // Stats row
            if let stats = entry.stats {
                HStack(spacing: 10) {
                    Text(Fmt.uptime(stats.uptimeSec))
                    HStack(spacing: 3) {
                        Text("CPU")
                        Text(Fmt.pct(stats.cpuUtilizationPct))
                            .foregroundStyle(Theme.muted)
                    }
                    HStack(spacing: 3) {
                        Text("MEM")
                        Text(Fmt.pct(stats.memoryUtilizationPct))
                            .foregroundStyle(Theme.muted)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Theme.blue : Theme.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Subviews

    private var typeBadge: some View {
        Text(entry.type.badge)
            .font(.system(size: 9, weight: .bold))
            .kerning(0.6)
            .textCase(.uppercase)
            .foregroundStyle(Theme.typeColor(entry.type))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.typeColor(entry.type).opacity(0.12))
            .clipShape(Capsule())
    }

    private var stateBadge: some View {
        HStack(spacing: 5) {
            if entry.state.isTransitioning {
                TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                    let seconds = timeline.date.timeIntervalSinceReferenceDate
                    let opacity = 0.35 + 0.65 * (0.5 + 0.5 * cos(seconds * 2 * .pi / 1.2))
                    Circle()
                        .fill(Theme.stateColor(entry.state))
                        .frame(width: 7, height: 7)
                        .opacity(opacity)
                }
            } else {
                Circle()
                    .fill(Theme.stateColor(entry.state))
                    .frame(width: 7, height: 7)
            }

            Text(entry.state.displayName)
                .font(.system(size: 9, weight: .bold))
                .kerning(0.5)
                .textCase(.uppercase)
        }
        .foregroundStyle(Theme.stateColor(entry.state))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Theme.stateColor(entry.state).opacity(0.12))
        .clipShape(Capsule())
    }

    private var metaText: String {
        var parts: [String] = []
        if let model = entry.device.model, !model.isEmpty { parts.append(model) }
        if let ip = entry.device.ipAddress { parts.append(ip) }
        return parts.joined(separator: " · ")
    }

}
