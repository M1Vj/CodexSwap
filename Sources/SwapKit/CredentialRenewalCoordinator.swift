import Foundation
import CryptoKit

enum CredentialRenewalResult: Sendable, Equatable {
    case renewed(Account)
    case invalidated
    case unavailable
    case notRenewable
}

actor CredentialRenewalCoordinator {
    typealias StandaloneRenew = @Sendable (Account, Bool, TimeInterval, Date) async -> StandaloneCredentialRenewalResult
    typealias OwnerRefresh = @Sendable (URL) async -> Bool

    private let store: AccountStore
    private let standaloneRenew: StandaloneRenew
    private let ownerRefresh: OwnerRefresh
    private let clock: @Sendable () -> Date
    private let onJoinedFlight: @Sendable () async -> Void
    private var inFlight: [String: Task<CredentialRenewalResult, Never>] = [:]
    private struct SourceVersion: Equatable {
        let modificationDate: Date?
        let digest: Data?
    }
    private struct Failure {
        let result: CredentialRenewalResult
        let sourceVersion: SourceVersion
        let retryAt: Date
        let cooldown: TimeInterval
    }
    private var failures: [String: Failure] = [:]
    private var admissionClosed = false

    var failureCooldownCount: Int { failures.count }

    init(
        store: AccountStore,
        standaloneRenewal: StandaloneCredentialRenewal,
        ownerRefresh: @escaping OwnerRefresh = { home in await OwnerCLICredentialRefresher().refresh(home: home) }
    ) {
        self.store = store
        self.standaloneRenew = { account, force, leadTime, now in
            await standaloneRenewal.renew(account, store: store, force: force, leadTime: leadTime, now: now)
        }
        self.ownerRefresh = ownerRefresh
        self.clock = { Date() }
        self.onJoinedFlight = {}
    }

    init(store: AccountStore, standaloneRenew: @escaping StandaloneRenew, ownerRefresh: @escaping OwnerRefresh,
         clock: @escaping @Sendable () -> Date = { Date() },
         onJoinedFlight: @escaping @Sendable () async -> Void = {}) {
        self.store = store
        self.standaloneRenew = standaloneRenew
        self.ownerRefresh = ownerRefresh
        self.clock = clock
        self.onJoinedFlight = onJoinedFlight
    }

    func closeAdmission() {
        admissionClosed = true
    }

    func renew(
        _ account: Account,
        force: Bool = false,
        leadTime: TimeInterval = 0,
        now: Date = Date()
    ) async -> CredentialRenewalResult {
        guard !admissionClosed, !Task.isCancelled else { return .unavailable }
        guard let source = AuthenticationRecovery.source(for: account),
              source.kind != .legacySnapshot, source.kind != .unknown,
              let path = source.path else { return .notRenewable }
        let authURL = source.kind == .managedHome
            ? URL(fileURLWithPath: path).appendingPathComponent("auth.json")
            : URL(fileURLWithPath: path)
        let key = authURL.standardizedFileURL.resolvingSymlinksInPath().path
        if let pending = inFlight[key] {
            await onJoinedFlight()
            let result = await pending.value
            if case .renewed(let renewed) = result, renewed.alias != account.alias {
                guard let current = await store.account(account.alias),
                      AuthenticationRecovery.source(for: current) == source,
                      (current.credentialAccountID ?? current.accountID) == (renewed.credentialAccountID ?? renewed.accountID),
                      let adopted = await store.hydrateFromManagedHome(account.alias),
                      adopted.accessToken == renewed.accessToken else { return .unavailable }
                return .renewed(adopted)
            }
            return result
        }
        if let failure = failures[key] {
            if failure.sourceVersion != sourceVersion(authURL) {
                failures.removeValue(forKey: key)
            } else if clock() < failure.retryAt {
                return failure.result
            }
        }
        guard force || (JWT.expiry(account.accessToken) ?? .distantPast).timeIntervalSince(now) <= leadTime else {
            return .renewed(account)
        }
        let task = Task { [store, standaloneRenew, ownerRefresh] in
            guard !Task.isCancelled else { return CredentialRenewalResult.unavailable }
            switch source.kind {
            case .standaloneHome:
                let result = await standaloneRenew(account, force, leadTime, now)
                switch result {
                case .renewed(let renewed): return CredentialRenewalResult.renewed(renewed)
                case .invalidated: return .invalidated
                case .unavailable: return .unavailable
                case .notOwned: return .notRenewable
                }
            case .managedHome, .nativeAuth:
                let correlationID = UUID()
                DiagnosticsLog.shared.record(component: .accounts, operation: .authentication, outcome: .started, correlationID: correlationID)
                let refreshed = await ownerRefresh(authURL.deletingLastPathComponent())
                guard refreshed,
                      let current = await store.account(account.alias),
                      AuthenticationRecovery.source(for: current) == source,
                      let tokens = StandaloneAccountRemoval.readBoundedAuthFile(authURL)?.tokens,
                      !tokens.refreshToken.isEmpty,
                      JWT.identity(fromAccessToken: tokens.accessToken).accountID == (account.credentialAccountID ?? account.accountID),
                      tokens.accountId.isEmpty || tokens.accountId == (account.credentialAccountID ?? account.accountID),
                      !JWT.isStale(tokens.accessToken, now: now),
                      let adopted = await store.hydrateFromManagedHome(account.alias),
                      adopted.accessToken == tokens.accessToken,
                      adopted.refreshToken == tokens.refreshToken,
                      adopted.idToken == tokens.idToken else {
                    DiagnosticsLog.shared.record(component: .accounts, operation: .authentication, outcome: .failed, level: .warning, code: .unavailable, correlationID: correlationID)
                    return .unavailable
                }
                DiagnosticsLog.shared.record(component: .accounts, operation: .authentication, outcome: .succeeded, correlationID: correlationID)
                return .renewed(adopted)
            case .legacySnapshot, .unknown:
                return .notRenewable
            }
        }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        switch result {
        case .unavailable, .invalidated:
            let cooldown = min((failures[key]?.cooldown ?? 900) * 2, 6 * 3_600)
            failures[key] = Failure(result: result, sourceVersion: sourceVersion(authURL),
                                    retryAt: clock().addingTimeInterval(cooldown), cooldown: cooldown)
        case .renewed:
            failures.removeValue(forKey: key)
        case .notRenewable:
            break
        }
        return result
    }

    private func sourceVersion(_ url: URL) -> SourceVersion {
        let modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        var digest: Data?
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 1_048_577), data.count <= 1_048_576 {
                digest = Data(SHA256.hash(data: data))
            }
        }
        return SourceVersion(modificationDate: modificationDate, digest: digest)
    }
}
