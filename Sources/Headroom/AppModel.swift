import AppKit
import CryptoKit
import Foundation
import HeadroomCore
import Observation

/// Resolves each sign-in, polls usage, applies offline readings, keeps transcript lists and saves
/// state. Tokens live only in this object's memory.
@Observable
@MainActor
final class AppModel {
    let paths: HeadroomPaths
    private(set) var state: HeadroomState
    private(set) var now = Date()
    private(set) var transcripts: [String: [TranscriptItem]] = [:]
    private(set) var desktopAccessUnavailable = false
    private(set) var lastUpdate: Date?
    var launchAtLogin = LoginItem.isEnabled {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do { try LoginItem.set(launchAtLogin) } catch { Log.write("Login item change failed: \(error)") }
        }
    }

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"

    private let http = HTTPClient()
    private let index: TranscriptIndex
    @ObservationIgnored private var schedule = PollSchedule()
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var keychainChanged = true
    @ObservationIgnored private var lastSaved: HeadroomState
    @ObservationIgnored private var lastIndex = IndexSnapshot()
    @ObservationIgnored private var listSignature = ""
    @ObservationIgnored private var stamps: [String: Date] = [:]
    @ObservationIgnored private var transcriptPolicy = TranscriptRefreshPolicy()
    @ObservationIgnored private var contentVisible = false

    // Sign-in material: memory only, never saved or logged.
    @ObservationIgnored private var safeStorageKey: [UInt8]?
    @ObservationIgnored private var safeStorageDenied = false
    @ObservationIgnored private var keyRequest: Task<Void, Never>?
    @ObservationIgnored private var desktopAccount: String?
    @ObservationIgnored private var desktopTokens: [DesktopToken] = []
    @ObservationIgnored private var cliToken: CLIToken?
    @ObservationIgnored private var cliAccount: String?
    @ObservationIgnored private var cliItemModified: Date?
    @ObservationIgnored private var cliChecked = false
    @ObservationIgnored private var codexAuth: CodexAuth?
    @ObservationIgnored private var profiles: [String: ClaudeProfile] = [:]

    init(paths: HeadroomPaths) {
        self.paths = paths
        let loaded = StateStore.load(from: paths.stateFile, now: Date())
        state = loaded
        lastSaved = loaded
        index = TranscriptIndex(paths: paths)
        cliAccount = loaded.accounts.first { $0.provider == .claude && $0.signedInOn.contains(.cli) }?.id
    }

    // MARK: View API

    var presentation: Presentation { Presentation(now: now) }

    var menuBarSegments: [MenuBarSegment] { presentation.menuBar(state.accounts) }

    func accounts(_ provider: Provider) -> [Account] {
        presentation.sortedAccounts(state.accounts.filter { $0.provider == provider })
    }

    func account(key: String) -> Account? {
        state.accounts.first { $0.key == key }
    }

    func refreshNow() {
        schedule.pollNow()
        requestRefresh(keychainChanged: true)
    }

    /// The popover or window is showing; transcript lists follow file changes at once while it is.
    func contentShown() {
        guard !contentVisible else { return }
        contentVisible = true
        requestRefresh()
    }

    func contentHidden() {
        contentVisible = false
    }

    func retryDesktopAccess() {
        safeStorageDenied = false
        desktopAccessUnavailable = false
        stamps[paths.claudeConfig.fsPath] = nil
        schedule.signInChanged("desktop")
        schedule.signInChanged("safe-storage")
        requestRefresh()
    }

    // MARK: Lifecycle

    func start() {
        Log.write("Headroom \(Self.version) started")
        let paths = self.paths
        let roots = [paths.claudeSupport, paths.claudeProjects, paths.claudeSessions, paths.codexHome, paths.keychainsDir].map(\.fsPath)
        watcher = FileWatcher(paths: roots, latency: 2) { [weak self] changed in
            let relevant = changed.filter { paths.isRelevant($0) }
            guard !relevant.isEmpty else { return }
            let keychain = relevant.contains { $0.hasPrefix(paths.keychainsDir.fsPath + "/") }
            let transcripts = relevant.contains { paths.isTranscriptSource($0) }
            let transcriptsOnly = relevant.allSatisfy { paths.isTranscriptSource($0) }
            Task { @MainActor in self?.filesChanged(keychain: keychain, transcripts: transcripts, transcriptsOnly: transcriptsOnly) }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestRefresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        requestRefresh(keychainChanged: true)
    }

    /// Sign-in changes refresh at once. Transcript changes wait for the next tick while nothing is showing.
    private func filesChanged(keychain: Bool, transcripts: Bool, transcriptsOnly: Bool) {
        if transcripts { transcriptPolicy.filesChanged() }
        guard !transcriptsOnly || contentVisible else { return }
        requestRefresh(keychainChanged: keychain)
    }

    func requestRefresh(keychainChanged: Bool = false) {
        if keychainChanged { self.keychainChanged = true }
        guard !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        Task {
            await refresh()
            refreshing = false
            if refreshAgain {
                refreshAgain = false
                requestRefresh()
            }
        }
    }

    private func refresh() async {
        now = Date()
        resolveDesktop()
        await resolveCLI()
        resolveCodex()
        readClaudeJSON()
        await pollDue()
        if transcriptPolicy.isDue(visible: contentVisible, now: now) {
            transcriptPolicy.refreshed(at: now)
            await refreshTranscripts()
        }
        await applyOfflineReadings()
        lastUpdate = Date()
        saveIfChanged()
    }

    // MARK: Sign-ins

    private func resolveDesktop() {
        let config = paths.claudeConfig
        guard let modified = modifiedDate(config) else {
            desktopAccount = nil
            desktopTokens = []
            if state.signOutIfMissing(.desktop, provider: .claude, sourcePresent: false, now: now) { schedule.signInChanged("desktop") }
            return
        }
        requestSafeStorageKeyIfNeeded()
        guard stamps[config.fsPath] != modified, let data = try? Data(contentsOf: config) else { return }
        stamps[config.fsPath] = modified

        var signIn = DesktopSignIn(accountUuid: DesktopTokenCache.lastKnownAccount(data), tokens: [])
        var unreadable = false
        if let key = safeStorageKey {
            do {
                signIn = try DesktopTokenCache.signIn(config: data, key: key, now: now)
            } catch {
                unreadable = true
                Log.write("Claude desktop token cache unreadable: \(error)")
            }
        }
        desktopAccessUnavailable = safeStorageDenied || unreadable
        // With readable tokens, none means signed out; without them, the last known account stands.
        let tokensReadable = safeStorageKey != nil && !unreadable
        let account = tokensReadable && signIn.tokens.isEmpty ? nil : signIn.accountUuid
        if account != desktopAccount || signIn.tokens.map(\.token) != desktopTokens.map(\.token) {
            schedule.signInChanged("desktop")
        }
        desktopAccount = account
        desktopTokens = signIn.tokens
        state.setSignedIn(.desktop, provider: .claude, id: account, now: now)
        if let account { state.setPlan(signIn.tokens.first?.plan, for: .claude, account, now: now) }
    }

    /// Asks for the Safe Storage password without holding up the rest of the refresh; the Keychain
    /// prompt may wait for the person.
    private func requestSafeStorageKeyIfNeeded() {
        guard safeStorageKey == nil, !safeStorageDenied, keyRequest == nil, schedule.isDue("safe-storage", now: Date()) else { return }
        keyRequest = Task {
            switch await KeychainReader.claudeSafeStoragePassword() {
            case .success(let password):
                safeStorageKey = try? SafeStorage.deriveKey(password: password)
                schedule.succeeded("safe-storage", now: Date())
            case .failure(.unavailableNow):
                // A locked screen or background session: ask again after the backoff, not on the next refresh.
                schedule.failedTransiently("safe-storage", now: Date())
                keyRequest = nil
                return
            case .failure(let failure):
                safeStorageDenied = true
                desktopAccessUnavailable = true
                Log.write("Claude Safe Storage unavailable: \(failure)")
            }
            keyRequest = nil
            stamps[paths.claudeConfig.fsPath] = nil
            requestRefresh()
        }
    }

    private func resolveCLI() async {
        guard keychainChanged || !cliChecked || schedule.isDue("cli", now: now) else { return }
        keychainChanged = false
        cliChecked = true
        let lookup = await KeychainReader.cliItemDates()
        var dates: KeychainItemDates?
        var fromFile = false
        if case .found(let found) = lookup {
            dates = found
        } else if let modified = modifiedDate(paths.claudeCredentialsFile) {
            dates = KeychainItemDates(created: modified, modified: modified)
            fromFile = true
        }
        guard let dates else {
            // Only a missing item signs the CLI out; a locked keychain leaves the last sign-in in place.
            if case .missing = lookup {
                cliToken = nil
                cliItemModified = nil
                cliAccount = nil
                if state.signOutIfMissing(.cli, provider: .claude, sourcePresent: false, now: now) { schedule.signInChanged("cli") }
            }
            return
        }
        guard dates.modified != cliItemModified else { return }
        let raw: String?
        if fromFile {
            raw = try? String(contentsOf: paths.claudeCredentialsFile, encoding: .utf8)
        } else {
            raw = await KeychainReader.cliSecret()
        }
        guard let raw, let token = CLICredentials.parse(raw) else { return }
        cliItemModified = dates.modified
        if token.accessToken != cliToken?.accessToken {
            cliToken = token
            schedule.signInChanged("cli")
        }
        guard !token.isExpired(at: now) else { return }
        switch await fetchProfile(token: token.accessToken) {
        case .ok(let profile):
            applyProfile(profile, fallbackPlan: token.plan)
            let from = state.cliTimeline.isEmpty ? (dates.created ?? now) : (dates.modified ?? now)
            Attribution.recordCLISignIn(profile.accountUuid, at: from, timeline: &state.cliTimeline)
            cliAccount = profile.accountUuid
            state.setSignedIn(.cli, provider: .claude, id: profile.accountUuid, now: now)
        case .auth(let status):
            Log.write("Claude CLI token refused (HTTP \(status))")
            schedule.failedAuth("cli")
        case .transient(let reason):
            Log.write("Claude CLI profile failed: \(reason)")
            cliItemModified = nil
        }
    }

    private func resolveCodex() {
        let file = paths.codexAuth
        guard let modified = modifiedDate(file) else {
            codexAuth = nil
            if state.signOutIfMissing(.codex, provider: .codex, sourcePresent: false, now: now) { schedule.signInChanged("codex") }
            return
        }
        guard stamps[file.fsPath] != modified else { return }
        stamps[file.fsPath] = modified
        let auth = (try? Data(contentsOf: file)).flatMap(CodexAPI.decodeAuth)
        if auth != codexAuth { schedule.signInChanged("codex") }
        codexAuth = auth
        state.setSignedIn(.codex, provider: .codex, id: auth?.accountId, now: now)
        if let auth {
            if let email = auth.email { state.setEmail(email, for: .codex, auth.accountId, now: now) }
            state.setPlan(auth.plan, for: .codex, auth.accountId, now: now)
        }
    }

    private func readClaudeJSON() {
        let file = paths.claudeJSON
        guard let modified = modifiedDate(file), stamps[file.fsPath] != modified else { return }
        stamps[file.fsPath] = modified
        guard let data = try? Data(contentsOf: file), let pair = ClaudeAccountFile.oauthAccount(data),
              state.claudeEmails[pair.accountUuid] == nil else { return }
        state.setEmail(pair.email, for: .claude, pair.accountUuid, now: now)
    }

    // MARK: Polling

    private func pollDue() async {
        if desktopAccount != nil, !desktopTokens.isEmpty, schedule.isDue("desktop", now: now) {
            await pollClaude(tokens: desktopTokens.map(\.token), fallbackPlan: desktopTokens.first?.plan, surface: "desktop")
        }
        if let token = cliToken, !token.isExpired(at: now), schedule.isDue("cli", now: now) {
            let sameAsDesktop = cliAccount != nil && cliAccount == desktopAccount
                && !desktopTokens.isEmpty && !schedule.isSetAside("desktop")
            if sameAsDesktop {
                schedule.succeeded("cli", now: now)
            } else {
                await pollClaude(tokens: [token.accessToken], fallbackPlan: token.plan, surface: "cli")
            }
        }
        if let auth = codexAuth, schedule.isDue("codex", now: now) {
            await pollCodex(auth)
        }
    }

    /// Polls Claude usage with the first token the endpoints accept.
    private func pollClaude(tokens: [String], fallbackPlan: String?, surface: String) async {
        for token in tokens {
            let profile: ClaudeProfile
            switch await fetchProfile(token: token) {
            case .ok(let found):
                profile = found
            case .auth:
                continue
            case .transient(let reason):
                Log.write("Claude \(surface) profile failed: \(reason)")
                schedule.failedTransiently(surface, now: now)
                return
            }
            switch await http.get(ClaudeAPI.usageURL, headers: ClaudeAPI.headers(token: token, version: Self.version)) {
            case .ok(let data):
                guard let reading = try? ClaudeAPI.decodeUsage(data, takenAt: Date()) else {
                    Log.write("Claude \(surface) usage response unreadable")
                    schedule.failedTransiently(surface, now: now)
                    return
                }
                applyProfile(profile, fallbackPlan: fallbackPlan)
                state.apply(reading, to: .claude, profile.accountUuid, now: now)
                schedule.succeeded(surface, now: now)
                return
            case .auth(let status):
                Log.write("Claude \(surface) usage refused (HTTP \(status))")
            case .transient(let reason):
                Log.write("Claude \(surface) usage failed: \(reason)")
                schedule.failedTransiently(surface, now: now)
                return
            }
        }
        schedule.failedAuth(surface)
    }

    private func fetchProfile(token: String) async -> FetchResult<ClaudeProfile> {
        let key = Self.fingerprint(token)
        if let cached = profiles[key] { return .ok(cached) }
        switch await http.get(ClaudeAPI.profileURL, headers: ClaudeAPI.headers(token: token, version: Self.version)) {
        case .ok(let data):
            guard let profile = try? ClaudeAPI.decodeProfile(data) else { return .transient("unreadable profile response") }
            profiles[key] = profile
            return .ok(profile)
        case .auth(let status):
            return .auth(status)
        case .transient(let reason):
            return .transient(reason)
        }
    }

    private func pollCodex(_ auth: CodexAuth) async {
        switch await http.get(CodexAPI.usageURL, headers: CodexAPI.headers(auth: auth, version: Self.version)) {
        case .ok(let data):
            guard let usage = try? CodexAPI.decodeUsage(data, takenAt: Date()) else {
                Log.write("Codex usage response unreadable")
                schedule.failedTransiently("codex", now: now)
                return
            }
            let id = usage.accountId ?? auth.accountId
            if let email = usage.email { state.setEmail(email, for: .codex, id, now: now) }
            state.setPlan(usage.plan, for: .codex, id, now: now)
            state.apply(usage.reading, to: .codex, id, now: now)
            schedule.succeeded("codex", now: now)
        case .auth(let status):
            Log.write("Codex usage refused (HTTP \(status))")
            schedule.failedAuth("codex")
        case .transient(let reason):
            Log.write("Codex usage failed: \(reason)")
            schedule.failedTransiently("codex", now: now)
        }
    }

    private func applyProfile(_ profile: ClaudeProfile, fallbackPlan: String?) {
        state.setEmail(profile.email, for: .claude, profile.accountUuid, now: now)
        state.setPlan(profile.plan ?? fallbackPlan, for: .claude, profile.accountUuid, now: now)
    }

    private static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Transcripts and offline readings

    private func refreshTranscripts() async {
        let emailToAccount = Dictionary(state.claudeEmails.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        let snapshot = await index.refresh(timeline: state.cliTimeline, emailToAccount: emailToAccount)
        lastIndex = snapshot
        if transcripts != snapshot.lists { transcripts = snapshot.lists }
        let signature = snapshot.lists.keys.sorted().map { key in
            "\(key.prefix(15)) \(snapshot.lists[key]?.count ?? 0)"
        }.joined(separator: "; ")
        if signature != listSignature {
            listSignature = signature
            Log.write("Transcript lists: \(signature)")
        }
        for account in snapshot.accountOrgs.keys { state.upsert(.claude, account, now: now) }
        for id in snapshot.codexAccountIds { state.upsert(.codex, id, now: now) }
        if !state.emailBackfillDone {
            let missing = Set(state.accounts.filter { $0.provider == .claude && $0.email == nil }.map(\.id))
            let votes = await index.emailVotes(for: missing, perAccount: 20)
            for (account, email) in Attribution.majorityEmails(votes) where state.account(.claude, account)?.email == nil {
                state.setEmail(email, for: .claude, account, now: now)
            }
            state.emailBackfillDone = true
        }
    }

    private func applyOfflineReadings() async {
        let history = paths.planUsageHistory
        if let modified = modifiedDate(history), stamps[history.fsPath] != modified,
           let data = try? Data(contentsOf: history), let samples = try? UsageSamples.parse(data) {
            stamps[history.fsPath] = modified
            let readings = UsageSamples.latestReadings(samples, accountOrgs: lastIndex.accountOrgs, activity: lastIndex.activity)
            for (account, reading) in readings { state.apply(reading, to: .claude, account, now: now) }
        }
        guard let account = codexAuth?.accountId,
              let rollout = CodexRollouts.newest(sessionsRoot: paths.codexSessions, now: now),
              let modified = modifiedDate(rollout), stamps[rollout.fsPath] != modified else { return }
        stamps[rollout.fsPath] = modified
        let snapshot = await Task.detached(priority: .utility) { CodexAPI.latestSnapshot(rollout: rollout) }.value
        if let snapshot, snapshot.accountId == nil || snapshot.accountId == account {
            state.apply(snapshot.reading, to: .codex, account, now: now)
        }
    }

    // MARK: Helpers

    private func saveIfChanged() {
        guard state != lastSaved else { return }
        do {
            try StateStore.save(state, to: paths.stateFile)
            lastSaved = state
        } catch {
            Log.write("Saving state failed: \(error)")
        }
    }

    private func modifiedDate(_ url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.fsPath)[.modificationDate] as? Date
    }
}
