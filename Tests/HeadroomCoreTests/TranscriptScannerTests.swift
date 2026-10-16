import Foundation
import Testing
@testable import HeadroomCore

struct TranscriptScannerTests {
    func append(_ url: URL, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @Test func desktopTranscriptHints() throws {
        let url = Fixture.url("claude-desktop-transcript.jsonl")
        let scan = try TranscriptScanner.scan(url: url)
        #expect(scan.entrypoint == "claude-desktop")
        #expect(scan.cwd == "/Users/example/Code/app")
        #expect(abs(scan.firstTimestamp!.timeIntervalSince1970 - 1_792_020_430.481) < 0.0001)
        #expect(scan.bridgeOwner == "11111111-2222-4333-8444-555555555555")
        #expect(scan.injectedEmail == "person@example.com")
        #expect(scan.customTitle == "Dark mode toggle in Settings")
        #expect(scan.firstPrompt == "Add a dark mode toggle")
        let size = try FileManager.default.attributesOfItem(atPath: url.fsPath)[.size] as! UInt64
        #expect(scan.scannedBytes == size)
    }

    @Test func sdkTranscriptPrompt() throws {
        let scan = try TranscriptScanner.scan(url: Fixture.url("claude-sdk-transcript.jsonl"))
        #expect(scan.entrypoint == "sdk-py")
        #expect(scan.bridgeOwner == nil)
        #expect(scan.injectedEmail == nil)
        #expect(scan.customTitle == nil)
        #expect(scan.firstPrompt?.hasPrefix("Review this change for security vulnerabilities.") == true)
        #expect((scan.firstPrompt?.count ?? 0) <= 80)
    }

    @Test func resumesFromLastCompleteLine() throws {
        let dir = try TempDir()
        let url = dir.url.appending(path: "s.jsonl")
        try FileManager.default.copyItem(at: Fixture.url("claude-sdk-transcript.jsonl"), to: url)
        let first = try TranscriptScanner.scan(url: url)
        try append(url, #"{"type":"custom-title","customTitle":"Security review","sessionId":"sess-sdk"}"# + "\n" + #"{"type":"custom-ti"#)
        let second = try TranscriptScanner.scan(url: url, resume: first)
        #expect(second.customTitle == "Security review")
        #expect(second.firstPrompt == first.firstPrompt)
        try append(url, #"tle","customTitle":"Final title","sessionId":"sess-sdk"}"# + "\n")
        let third = try TranscriptScanner.scan(url: url, resume: second)
        #expect(third.customTitle == "Final title")
        #expect(third.scannedBytes > second.scannedBytes)
    }

    @Test func firstInjectedEmail() {
        #expect(TranscriptScanner.firstInjectedEmail(url: Fixture.url("claude-desktop-transcript.jsonl")) == "person@example.com")
        #expect(TranscriptScanner.firstInjectedEmail(url: Fixture.url("claude-sdk-transcript.jsonl")) == nil)
    }
}
