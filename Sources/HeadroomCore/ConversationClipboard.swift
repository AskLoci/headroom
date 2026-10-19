import AppKit

/// Writes redacted conversation text. Copies stay on this Mac unless the person changes the setting.
@MainActor
public enum ConversationClipboard {
    public static let localOnlyKey = "conversationClipboardLocalOnly"
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    @discardableResult
    public static func copy(_ text: String, localOnly: Bool = true, to pasteboard: NSPasteboard = .general) -> Bool {
        copy(text, localOnly: localOnly,
             prepare: { _ = pasteboard.prepareForNewContents(with: $0) },
             write: { pasteboard.writeObjects([$0]) })
    }

    static func copy(_ text: String, localOnly: Bool, prepare: (NSPasteboard.ContentsOptions) -> Void,
                     write: (NSPasteboardItem) -> Bool) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(SecretRedactor.redact(text), forType: .string),
              item.setData(Data(), forType: concealedType) else { return false }
        prepare(localOnly ? .currentHostOnly : [])
        return write(item)
    }
}

#if DEBUG && canImport(Testing)
import Testing

@MainActor
struct ConversationClipboardTests {
    @Test(arguments: [true, false])
    func appliesPrivacyChoiceAndConcealedMarker(_ localOnly: Bool) {
        var options: NSPasteboard.ContentsOptions?
        var written: NSPasteboardItem?
        let success = ConversationClipboard.copy("API_KEY=hidden-value", localOnly: localOnly,
            prepare: { options = $0 }, write: { written = $0; return true })
        #expect(success)
        #expect(options?.contains(.currentHostOnly) == localOnly)
        #expect(written?.string(forType: .string) == "API_KEY=[REDACTED]")
        #expect(written?.types.contains(ConversationClipboard.concealedType) == true)
    }

    @Test func reportsWriteFailure() {
        #expect(!ConversationClipboard.copy("text", localOnly: true, prepare: { _ in }, write: { _ in false }))
    }

    @Test func writesToAnIsolatedNativePasteboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(ConversationClipboard.copy("token=hidden-value", to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "token=[REDACTED]")
        #expect(pasteboard.types?.contains(ConversationClipboard.concealedType) == true)
    }
}
#endif
