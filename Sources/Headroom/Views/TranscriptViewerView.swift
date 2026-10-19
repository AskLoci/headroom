import AppKit
import HeadroomCore
import SwiftUI
import UniformTypeIdentifiers

/// One window per transcript; opening it again brings the existing window forward.
@MainActor
final class ViewerWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [String: ViewerWindowController] = [:]
    private let itemKey: String

    static func show(_ item: TranscriptItem) {
        let key = "\(item.provider.rawValue):\(item.id)"
        let controller = open[key] ?? ViewerWindowController(item: item, key: key)
        if open[key] != nil {
            // A fresh view reloads the transcript, which may have grown since the window opened.
            controller.window?.contentView = NSHostingView(rootView: TranscriptViewerView(item: item))
        }
        open[key] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private init(item: TranscriptItem, key: String) {
        itemKey = key
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = item.title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TranscriptViewerView(item: item))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        Self.open[itemKey] = nil
    }
}

struct TranscriptViewerView: View {
    let item: TranscriptItem
    @AppStorage(ConversationClipboard.localOnlyKey) private var localOnly = true
    @State private var entries: [ViewerEntry]?
    @State private var failed = false
    @State private var copied = false
    @State private var copiedContext = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                if let cwd = item.cwd {
                    Text(cwd)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { exportButtons; navigationButtons }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) { exportButtons }
                        HStack(spacing: 8) { navigationButtons }
                    }
                }
                .controlSize(.small)
                Text("Recognized secrets are hidden in copied and saved conversations. Review before sharing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            Divider()
            content
        }
        .frame(minWidth: 480, minHeight: 360)
        .task { await load() }
    }

    @ViewBuilder
    private var exportButtons: some View {
        Button(copiedContext ? "Copied" : "Copy as Context") { copyContext() }
            .disabled(entries == nil)
        Button("Save as Markdown…") { save() }
            .disabled(entries == nil)
    }

    @ViewBuilder
    private var navigationButtons: some View {
        Button(copied ? "Copied" : "Copy Resume Command") {
            guard let command = item.resumeCommand else { return }
            copied = ConversationClipboard.copy(command, localOnly: localOnly)
        }
        .disabled(item.resumeCommand == nil)
        .help(item.resumeCommand == nil ? "This conversation has no valid resume command" : "Copy the command to resume this conversation")
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) }
    }

    @ViewBuilder
    private var content: some View {
        if let entries {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(entries) { EntryView(entry: $0) }
                }
                .padding(14)
            }
        } else if failed {
            Text("This transcript could not be read.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() async {
        let item = item
        let parsed = await Task.detached(priority: .userInitiated) { () -> [ViewerEntry]? in
            switch item.provider {
            case .claude: try? TranscriptViewer.claudeEntries(url: item.fileURL)
            case .codex: try? TranscriptViewer.codexEntries(url: item.fileURL)
            }
        }.value
        if let parsed { entries = parsed } else { failed = true }
    }

    /// Both exports re-read the transcript, so they include turns added after the window opened.
    private func copyContext() {
        let item = item
        Task {
            let text = await Task.detached(priority: .userInitiated) { () -> String? in
                try? Handoff.export(item: item, lastActive: Presentation(now: Date()).timeText(item.lastActivity), limit: Handoff.copyLimit)
            }.value
            guard let text else { return }
            copiedContext = ConversationClipboard.copy(text, localOnly: localOnly)
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Handoff.fileName(for: item)
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let item = item
        Task.detached(priority: .userInitiated) {
            do {
                let text = try Handoff.export(item: item, lastActive: Presentation(now: Date()).timeText(item.lastActivity))
                try Data(text.utf8).write(to: url, options: .atomic)
            } catch {
                Log.write("Saving a conversation export failed: \(error)")
            }
        }
    }
}

struct EntryView: View {
    let entry: ViewerEntry

    var body: some View {
        switch entry.role {
        case .user:
            VStack(alignment: .leading, spacing: 3) {
                Text("You")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(TranscriptViewer.clipped(entry.text))
                    .textSelection(.enabled)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.10)))
        case .assistant:
            Text(TranscriptViewer.clipped(entry.text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            Label(entry.text, systemImage: "wrench.and.screwdriver")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
