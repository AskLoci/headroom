import AppKit
import HeadroomCore
import SwiftUI

/// Copies a conversation as a Markdown handoff, ready to paste into a new session.
struct CopyContextButton: View {
    let item: TranscriptItem
    @State private var status: Status = .idle

    enum Status {
        case idle, working, copied, failed
    }

    var body: some View {
        Button {
            Task { await copy() }
        } label: {
            Image(systemName: symbol)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .disabled(status == .working)
        .help(item.unfinished == nil ? "Copy this conversation to paste into a new session"
                                     : "Copy this unfinished conversation to continue it in a new session")
    }

    private var symbol: String {
        switch status {
        case .idle: "doc.on.doc"
        case .working: "ellipsis"
        case .copied: "checkmark"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func copy() async {
        status = .working
        let item = item
        let text = await Task.detached(priority: .userInitiated) { () -> String? in
            try? Handoff.export(item: item, lastActive: Presentation(now: Date()).timeText(item.lastActivity), limit: Handoff.copyLimit)
        }.value
        if let text {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            status = .copied
        } else {
            status = .failed
        }
        try? await Task.sleep(for: .seconds(2))
        status = .idle
    }
}
