import HeadroomCore
import SwiftUI

struct AccountDetailView: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let back: () -> Void

    var body: some View {
        let presentation = model.presentation
        let items = model.transcripts[account.key] ?? []
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button(action: back) { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                Text(account.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let plan = account.plan {
                    Text(plan)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        LimitRow(name: "Weekly", window: account.lastReading?.weekly, weekly: true, presentation: presentation)
                        LimitRow(name: "5-hour", window: presentation.currentSession(account.lastReading), weekly: false, presentation: presentation)
                        ForEach(account.lastReading?.scoped ?? [], id: \.name) { limit in
                            LimitRow(name: limit.name, window: UsageWindow(percent: limit.percent, resetsAt: limit.resetsAt),
                                     weekly: true, presentation: presentation)
                        }
                        if let reading = account.lastReading, let stale = presentation.staleText(reading) {
                            Text(stale)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text("Recent sessions")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if items.isEmpty {
                        Text("No sessions found for this account.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 4) {
                            Button {
                                ViewerWindowController.show(item)
                            } label: {
                                TranscriptRow(item: item, presentation: presentation)
                            }
                            .buttonStyle(.plain)
                            CopyContextButton(item: item)
                                .padding(.top, 6)
                        }
                    }
                }
                .padding(12)
            }
        }
    }
}

struct LimitRow: View {
    let name: String
    let window: UsageWindow?
    let weekly: Bool
    let presentation: Presentation

    var body: some View {
        let percent = presentation.effectivePercent(window)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "–")
                    .font(.system(size: 12).monospacedDigit())
            }
            UsageBar(percent: percent)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var caption: String? {
        if weekly { return presentation.resetText(window) }
        guard window?.resetsAt != nil else { return nil }
        return presentation.resetText(window, restartedLabel: "Restarted")
    }
}

struct TranscriptRow: View {
    let item: TranscriptItem
    let presentation: Presentation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .font(.system(size: 12))
                .lineLimit(1)
            // The project name gives way first, so the time stays whole on one line.
            HStack(spacing: 0) {
                if !item.project.isEmpty {
                    Text(item.project)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(" · ").fixedSize()
                }
                Text(([presentation.relative(item.lastActivity)] + (item.archived ? ["Archived"] : [])).joined(separator: " · "))
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if let reason = item.unfinished {
                Label("Unfinished · \(reason.label)", systemImage: "exclamationmark.circle")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .help(reason.detail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        .contentShape(Rectangle())
    }
}
