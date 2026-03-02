import SwiftUI

struct EventLogView: View {
    @Environment(DeviceManager.self) private var manager
    @Binding var collapsed: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Event Log")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.muted)

                Spacer()

                Button("Clear") {
                    manager.clearLog()
                }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() }
                } label: {
                    Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() }
            }

            // Log body
            if !collapsed {
                Divider().overlay(Theme.border)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(manager.logEntries) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(Fmt.time(entry.time))
                                        .foregroundStyle(Theme.dim)
                                        .frame(width: 68, alignment: .leading)

                                    Text(entry.message)
                                        .foregroundStyle(logColor(entry.level))
                                }
                                .font(.system(size: 10, design: .monospaced))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 2)
                                .id(entry.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 158)
                    .onChange(of: manager.logEntries.count) {
                        if let last = manager.logEntries.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Divider().overlay(Theme.border)
        }
    }

    private func logColor(_ level: LogEntry.LogLevel) -> Color {
        switch level {
        case .info: Theme.text
        case .success: Theme.green
        case .warn: Theme.amber
        case .error: Theme.red
        }
    }
}
