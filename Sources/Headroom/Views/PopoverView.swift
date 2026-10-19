import AppKit
import HeadroomCore
import SwiftUI

struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedKey: String?

    var body: some View {
        Group {
            if let key = selectedKey, let account = model.account(key: key) {
                AccountDetailView(account: account) { selectedKey = nil }
            } else {
                accountList
            }
        }
        .frame(width: 360, height: 520)
    }

    private var accountList: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section(.claude, title: "Claude")
                    section(.codex, title: "Codex")
                }
                .padding(12)
            }
            Divider()
            FooterView()
        }
    }

    private func section(_ provider: Provider, title: String) -> some View {
        let accounts = model.accounts(provider)
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if provider == .claude && model.desktopAccessUnavailable {
                HStack {
                    Text("Claude desktop reset times are unavailable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { model.retryDesktopAccess() }
                        .controlSize(.small)
                }
            }
            if accounts.isEmpty {
                Text(provider == .claude ? "No Claude accounts on this Mac yet." : "No Codex accounts on this Mac yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(accounts, id: \.key) { account in
                AccountRowView(account: account, presentation: model.presentation)
                    .onTapGesture { selectedKey = account.key }
            }
        }
    }
}

struct FooterView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ConversationClipboard.localOnlyKey) private var localOnly = true

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            Text(model.lastUpdate.map { "Updated \(model.presentation.timeText($0))" } ?? "Updating…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                model.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
            Menu {
                Toggle("Keep copied conversations on this Mac", isOn: $localOnly)
            } label: {
                Image(systemName: "lock")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Clipboard privacy")
            Toggle("Launch at Login", isOn: $model.launchAtLogin)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.caption)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
