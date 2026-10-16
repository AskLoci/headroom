import Foundation
import HeadroomCore
import Security

enum KeychainFailure: Error, Sendable {
    case denied
    case notFound
    case unavailableNow
    case unreadable
    case status(OSStatus)
}

/// The CLI's Keychain item: present (with its dates), gone, or unreadable for now (for example a locked keychain).
enum CLIItemLookup: Sendable {
    case found(KeychainItemDates)
    case missing
    case unavailable
}

enum KeychainReader {
    /// Claude desktop's Safe Storage password. The first read shows the macOS Keychain prompt;
    /// "Always Allow" lets later launches of the same signed app read it silently.
    static func claudeSafeStoragePassword() async -> Result<String, KeychainFailure> {
        await Task.detached(priority: .utility) { () -> Result<String, KeychainFailure> in
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: "Claude Safe Storage",
                kSecAttrAccount: "Claude Key",
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else { return .failure(.unreadable) }
                return .success(password)
            case errSecUserCanceled, errSecAuthFailed: return .failure(.denied)
            case errSecInteractionNotAllowed: return .failure(.unavailableNow)
            case errSecItemNotFound: return .failure(.notFound)
            default: return .failure(.status(status))
            }
        }.value
    }

    /// Creation and modification dates of the CLI's "Claude Code-credentials" item, read without its secret.
    static func cliItemDates() async -> CLIItemLookup {
        await Task.detached(priority: .utility) {
            let result = security(["find-generic-password", "-s", "Claude Code-credentials", "-a", NSUserName()])
            switch result.status {
            case 0: return .found(KeychainAttributes.parse(result.output))
            case 44: return .missing // errSecItemNotFound
            default: return .unavailable
            }
        }.value
    }

    /// The CLI's stored credentials. Claude Code writes this item with `security`, so this read shows no prompt.
    static func cliSecret() async -> String? {
        await Task.detached(priority: .utility) {
            let result = security(["find-generic-password", "-s", "Claude Code-credentials", "-a", NSUserName(), "-w"])
            return result.status == 0 ? result.output : nil
        }.value
    }

    private static func security(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
