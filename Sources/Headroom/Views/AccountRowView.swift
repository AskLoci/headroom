import HeadroomCore
import SwiftUI

struct AccountRowView: View {
    let account: Account
    let presentation: Presentation

    var body: some View {
        let weekly = account.lastReading?.weekly
        let percent = presentation.effectivePercent(weekly)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(account.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                planAndSignIns
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .fixedSize()
            }
            HStack(spacing: 10) {
                UsageBar(percent: percent)
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "–")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
            }
            HStack(spacing: 10) {
                Text(presentation.resetText(weekly))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let session = presentation.effectivePercent(presentation.currentSession(account.lastReading)) {
                    Text("5h \(Int(session.rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ForEach(presentation.modelChips(account.lastReading), id: \.name) { limit in
                    Text("\(limit.name) \(Int(limit.percent.rounded()))%")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Level(percent: limit.percent).color)
                }
            }
            if let reading = account.lastReading, let stale = presentation.staleText(reading) {
                Text(stale)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .contentShape(Rectangle())
    }

    /// "Max 20x  ·  Desktop": the plan in grey, then where the account is signed in, in the accent colour.
    private var planAndSignIns: Text {
        let signIns = account.signedInOn.sorted().map(\.label).joined(separator: " · ")
        let plan = account.plan.map { signIns.isEmpty ? $0 : $0 + "  ·  " } ?? ""
        return Text("\(Text(plan).foregroundStyle(.secondary))\(Text(signIns).foregroundStyle(.tint))")
    }
}

struct UsageBar: View {
    let percent: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.10))
                if let percent {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Level(percent: percent).color)
                        .frame(width: max(3, geometry.size.width * min(percent, 100) / 100))
                }
            }
        }
        .frame(height: 5)
    }
}

extension Level {
    var color: Color {
        switch self {
        case .normal: .accentColor
        case .warning: .orange
        case .critical: .red
        }
    }
}
