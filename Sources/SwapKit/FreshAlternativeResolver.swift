import Foundation

/// Shared fresh-account resolution for the app and standalone `swapd` proxy.
///
/// The resolver is intentionally kept at the SwapKit boundary so every proxy
/// entry point hydrates external account state, verifies usage, and reserves the
/// same eligible alternative before replaying a request.
public enum FreshAlternativeResolver {
    public static func resolve(
        store: AccountStore,
        usage: any UsageFetching,
        currentAlias: String,
        allowedAliases: [String]?
    ) async -> Account? {
        await resolve(
            store: store,
            usage: usage,
            currentAlias: currentAlias,
            allowedAliases: allowedAliases,
            beforeHydrate: nil
        )
    }

    static func resolve(
        store: AccountStore,
        usage: any UsageFetching,
        currentAlias: String,
        allowedAliases: [String]?,
        beforeHydrate: (@Sendable (String) async -> Void)?
    ) async -> Account? {
        let allowed = allowedAliases.map(Set.init)
        let candidates = await store.activeAccounts().filter { account in
            account.alias != currentAlias
                && (allowed?.contains(account.alias) ?? true)
                && !account.isArchived
                && account.routingEnabled
        }
        var verifiedAliases: [String] = []
        for candidate in candidates {
            await beforeHydrate?(candidate.alias)
            guard let fresh = await store.hydrateFromManagedHome(candidate.alias),
                  !fresh.isArchived,
                  fresh.routingEnabled,
                  !fresh.accessToken.isEmpty,
                  !fresh.needsLogin,
                  let windows = try? await usage.fetch(
                      accessToken: fresh.accessToken,
                      accountID: fresh.accountID
                  ),
                  !windows.isEmpty else { continue }
            await store.updateUsage(candidate.alias, windows: windows)
            verifiedAliases.append(candidate.alias)
        }
        return await store.reserveBestEligible(among: verifiedAliases, avoidingLeased: true)
    }

    /// Builds a standalone proxy with the same fresh-alternative resolver used
    /// by AppEngine. `swapd proxy` and `swapd run` both use this constructor.
    public static func makeProxy(
        store: AccountStore,
        config: ProxyServer.Config = ProxyServer.Config(),
        settingsProvider: @escaping @Sendable () async -> Settings,
        usage: any UsageFetching = UsageClient(),
        verbose: Bool = false
    ) -> ProxyServer {
        ProxyServer(
            store: store,
            config: config,
            settingsProvider: settingsProvider,
            freshAlternative: { currentAlias, allowedAliases in
                await Self.resolve(
                    store: store,
                    usage: usage,
                    currentAlias: currentAlias,
                    allowedAliases: allowedAliases
                )
            },
            verbose: verbose
        )
    }
}
