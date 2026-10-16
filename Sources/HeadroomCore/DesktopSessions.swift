import Foundation

public struct DesktopSession: Sendable, Equatable {
    public var accountUuid: String
    public var orgUuid: String
    public var localId: String
    public var cliSessionId: String?
    public var title: String?
    public var cwd: String?
    public var createdAt: Date?
    public var lastActivityAt: Date?
    public var isArchived: Bool
}

/// The Claude desktop app's Code sessions: `claude-code-sessions/<accountUuid>/<orgUuid>/local_*.json`.
public enum DesktopSessions {
    public struct MetadataFile: Sendable, Equatable {
        public var url: URL
        public var accountUuid: String
        public var orgUuid: String
    }

    struct Body: Decodable {
        let sessionId: String?
        let cliSessionId: String?
        let title: String?
        let cwd: String?
        let createdAt: Double?
        let lastActivityAt: Double?
        let isArchived: Bool?
    }

    public static func parse(_ data: Data, accountUuid: String, orgUuid: String, fileStem: String) throws -> DesktopSession {
        let body = try JSONDecoder().decode(Body.self, from: data)
        return DesktopSession(
            accountUuid: accountUuid, orgUuid: orgUuid, localId: body.sessionId ?? fileStem,
            cliSessionId: body.cliSessionId, title: body.title, cwd: body.cwd,
            createdAt: body.createdAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            lastActivityAt: body.lastActivityAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            isArchived: body.isArchived ?? false
        )
    }

    struct ArchivedIndex: Decodable { let archived: [String]? }

    /// Session ids listed in an org folder's archived-sessions.idx.
    public static func archivedIds(orgDir: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: orgDir.appending(path: "archived-sessions.idx")),
              let index = try? JSONDecoder().decode(ArchivedIndex.self, from: data)
        else { return [] }
        return Set(index.archived ?? [])
    }

    /// Account UUID → org UUIDs, read from the folder layout.
    public static func accountOrgs(root: URL) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        let fm = FileManager.default
        for account in (try? fm.contentsOfDirectory(atPath: root.fsPath)) ?? [] where isUUID(account) {
            let orgs = (try? fm.contentsOfDirectory(atPath: root.appending(path: account).fsPath)) ?? []
            result[account] = Set(orgs.filter(isUUID))
        }
        return result
    }

    public static func metadataFiles(root: URL) -> [MetadataFile] {
        var files: [MetadataFile] = []
        for (account, orgs) in accountOrgs(root: root) {
            for org in orgs {
                let folder = root.appending(path: "\(account)/\(org)", directoryHint: .isDirectory)
                for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.fsPath)) ?? []
                where name.hasPrefix("local_") && name.hasSuffix(".json") {
                    files.append(MetadataFile(url: folder.appending(path: name), accountUuid: account, orgUuid: org))
                }
            }
        }
        return files
    }

    static func isUUID(_ name: String) -> Bool { UUID(uuidString: name) != nil }
}
