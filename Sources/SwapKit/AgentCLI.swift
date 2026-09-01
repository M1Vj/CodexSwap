import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Stable machine-readable contract

/// Exit statuses intentionally follow the portable `sysexits(3)` values, with
/// 130 reserved for cancellation.  The agent CLI never exposes an underlying
/// service error or a process-specific status in its envelope.
public enum AgentCLIExitCode: Int, Sendable {
    case ok = 0
    case usage = 64
    case data = 65
    case unavailable = 69
    case software = 70
    case tempFailure = 75
    case permission = 77
    case cancelled = 130
}

public struct AgentCLIErrorPayload: Codable, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// A small JSON value tree keeps the envelope independent from implementation
/// structs while retaining deterministic, Codable output for tests and other
/// agents.
public enum AgentCLIJSONValue: Codable, Sendable, Equatable {
    case object([String: AgentCLIJSONValue])
    case array([AgentCLIJSONValue])
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var result: [String: AgentCLIJSONValue] = [:]
            for key in keyed.allKeys {
                result[key.stringValue] = try keyed.decode(AgentCLIJSONValue.self, forKey: key)
            }
            self = .object(result)
            return
        }
        if var unkeyed = try? decoder.unkeyedContainer() {
            var result: [AgentCLIJSONValue] = []
            while !unkeyed.isAtEnd {
                result.append(try unkeyed.decode(AgentCLIJSONValue.self))
            }
            self = .array(result)
            return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let bool = try? single.decode(Bool.self) {
            self = .bool(bool)
        } else if let integer = try? single.decode(Int.self) {
            self = .integer(integer)
        } else if let number = try? single.decode(Double.self) {
            self = .number(number)
        } else {
            self = .string(try single.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let value):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for key in value.keys.sorted() {
                guard let codingKey = DynamicCodingKey(stringValue: key), let item = value[key] else { continue }
                try container.encode(item, forKey: codingKey)
            }
        case .array(let value):
            var container = encoder.unkeyedContainer()
            for item in value { try container.encode(item) }
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .integer(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }

    public static func fromEncodable<T: Encodable>(_ value: T) throws -> AgentCLIJSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try Self.fromJSONData(encoder.encode(value))
    }

    public static func fromJSONData(_ data: Data) throws -> AgentCLIJSONValue {
        let decoder = JSONDecoder()
        return try decoder.decode(AgentCLIJSONValue.self, from: data)
    }

    private struct DynamicCodingKey: CodingKey, Hashable {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}

public struct AgentCLIEnvelope: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let command: String
    public let ok: Bool
    public let data: AgentCLIJSONValue?
    public let warnings: [String]?
    public let error: AgentCLIErrorPayload?

    public init(
        schemaVersion: Int = 1,
        command: String,
        ok: Bool,
        data: AgentCLIJSONValue? = nil,
        warnings: [String]? = nil,
        error: AgentCLIErrorPayload? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.command = command
        self.ok = ok
        self.data = data
        self.warnings = warnings?.isEmpty == true ? nil : warnings
        self.error = error
    }

    public static func success(
        command: String,
        data: AgentCLIJSONValue? = nil,
        warnings: [String]? = nil
    ) -> Self {
        Self(command: command, ok: true, data: data, warnings: warnings)
    }

    public static func failure(
        command: String,
        code: String,
        message: String,
        warnings: [String]? = nil,
        data: AgentCLIJSONValue? = nil
    ) -> Self {
        Self(
            command: command,
            ok: false,
            data: data,
            warnings: warnings,
            error: AgentCLIErrorPayload(code: code, message: message)
        )
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, command, ok, data, warnings, error }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(command, forKey: .command)
        try container.encode(ok, forKey: .ok)
        try container.encode(data ?? .null, forKey: .data)
        try container.encode(warnings ?? [], forKey: .warnings)
        try container.encodeIfPresent(error, forKey: .error)
        if error == nil { try container.encodeNil(forKey: .error) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        command = try container.decode(String.self, forKey: .command)
        ok = try container.decode(Bool.self, forKey: .ok)
        data = try container.decodeIfPresent(AgentCLIJSONValue.self, forKey: .data)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings)
        error = try container.decodeIfPresent(AgentCLIErrorPayload.self, forKey: .error)
    }
}

public enum AgentCLIJSON {
    public static func encode(_ envelope: AgentCLIEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }
}

public struct AgentCLIResult: Sendable {
    public let envelope: AgentCLIEnvelope
    public let exitCode: Int

    public init(envelope: AgentCLIEnvelope, exitCode: AgentCLIExitCode) {
        self.envelope = envelope
        self.exitCode = exitCode.rawValue
    }

    public init(envelope: AgentCLIEnvelope, exitCode: Int) {
        self.envelope = envelope
        self.exitCode = exitCode
    }

    public var encoded: Data { (try? AgentCLIJSON.encode(envelope)) ?? Data() }
}

// MARK: - Parser

public struct AgentCLIOptions: Sendable, Equatable {
    public let json: Bool
    public let confirm: Bool
    public let dryRun: Bool
    /// Optional per-account routing/sticky mode (`--enable`/`--disable`).
    /// `nil` retains the sticky toggle behavior for backwards-compatible calls.
    public let accountMode: Bool?

    public init(json: Bool = false, confirm: Bool = false, dryRun: Bool = false, accountMode: Bool? = nil) {
        self.json = json
        self.confirm = confirm
        self.dryRun = dryRun
        self.accountMode = accountMode
    }
}

public enum AgentCLIOperation: Sendable, Equatable {
    case help
    case status
    case accountsList
    case accountsShow(String)
    case accountsImport
    case accountsReconcile
    case accountSwitch(String)
    case accountSticky(String, desired: Bool?)
    case accountRouting(String, enabled: Bool)
    case accountUsageLimitShow(String)
    case accountUsageLimitSet(String, fiveHour: Int?, weekly: Int?, enabled: Bool?)
    case accountRank(String, rank: Int)
    case accountArchive(String)
    case accountRestore(String)
    case accountRemove(String)
    case quotaReport
    case warmupAll
    case resetStatus
    case resetUse(String)
    case routingGet
    case routingEnable
    case routingDisable
    case routingRepair
    case settingsGet(String?)
    case settingsSet(String, String)
    case warmupAccount(String)
}

public struct AgentCLICommand: Sendable, Equatable {
    public let operation: AgentCLIOperation
    public let options: AgentCLIOptions

    public init(operation: AgentCLIOperation, options: AgentCLIOptions = AgentCLIOptions()) {
        self.operation = operation
        self.options = options
    }

    public var canonicalName: String {
        switch operation {
        case .help: return "agent help"
        case .status: return "agent status"
        case .accountsList: return "agent accounts list"
        case .accountsShow: return "agent accounts show"
        case .accountsImport: return "agent accounts import"
        case .accountsReconcile: return "agent accounts reconcile"
        case .accountSwitch: return "agent account switch"
        case .accountSticky: return "agent account sticky"
        case .accountRouting: return "agent account routing"
        case .accountUsageLimitShow: return "agent account usage-limit show"
        case .accountUsageLimitSet: return "agent account usage-limit set"
        case .accountRank: return "agent account rank"
        case .accountArchive: return "agent account archive"
        case .accountRestore: return "agent account restore"
        case .accountRemove: return "agent account remove"
        case .quotaReport: return "agent quota report"
        case .warmupAll: return "agent warmup all"
        case .resetStatus: return "agent reset status"
        case .resetUse: return "agent reset use"
        case .routingGet: return "agent routing get"
        case .routingEnable: return "agent routing enable"
        case .routingDisable: return "agent routing disable"
        case .routingRepair: return "agent routing repair"
        case .settingsGet: return "agent settings get"
        case .settingsSet: return "agent settings set"
        case .warmupAccount: return "agent warmup account"
        }
    }
}

public enum AgentCLIParseError: Error, LocalizedError, Sendable, Equatable {
    case missingNamespace
    case unknownCommand
    case missingArgument
    case invalidArgument
    case invalidFlag
    case invalidInteger
    case unsupportedFlag

    public var errorDescription: String? {
        switch self {
        case .missingNamespace: return "agent namespace required"
        case .unknownCommand: return "unknown agent command"
        case .missingArgument: return "required agent argument missing"
        case .invalidArgument: return "invalid agent argument"
        case .invalidFlag: return "invalid agent flag"
        case .invalidInteger: return "invalid numeric agent argument"
        case .unsupportedFlag: return "flag is not supported for this agent command"
        }
    }
}

public enum AgentCLIParser {
    public static func parse(_ arguments: [String]) throws -> AgentCLICommand {
        guard arguments.first == "agent" else { throw AgentCLIParseError.missingNamespace }
        var positional: [String] = []
        var json = false
        var confirm = false
        var dryRun = false
        var accountMode: Bool?
        var fiveHourPercent: Int?
        var weeklyPercent: Int?
        var seenFlags = Set<String>()
        var usageLimitModeAliasUsed = false

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            switch argument {
            case "--json":
                guard seenFlags.insert(argument).inserted else { throw AgentCLIParseError.invalidFlag }
                json = true
            case "--confirm":
                guard seenFlags.insert(argument).inserted else { throw AgentCLIParseError.invalidFlag }
                confirm = true
            case "--dry-run":
                guard seenFlags.insert(argument).inserted else { throw AgentCLIParseError.invalidFlag }
                dryRun = true
            case "--enable", "--on":
                guard seenFlags.insert(argument).inserted else { throw AgentCLIParseError.invalidFlag }
                guard accountMode == nil else { throw AgentCLIParseError.invalidFlag }
                if argument == "--on" { usageLimitModeAliasUsed = true }
                accountMode = true
            case "--disable", "--off":
                guard seenFlags.insert(argument).inserted else { throw AgentCLIParseError.invalidFlag }
                guard accountMode == nil else { throw AgentCLIParseError.invalidFlag }
                if argument == "--off" { usageLimitModeAliasUsed = true }
                accountMode = false
            case "--five-hour":
                guard seenFlags.insert(argument).inserted else { throw AgentCLIParseError.invalidFlag }
                guard index < arguments.count else { throw AgentCLIParseError.missingArgument }
                let rawValue = arguments[index]
                index += 1
                guard let value = Int(rawValue), (1...100).contains(value) else {
                    throw AgentCLIParseError.invalidInteger
                }
                fiveHourPercent = value
            case "--weekly":
                guard seenFlags.insert(argument).inserted else { throw AgentCLIParseError.invalidFlag }
                guard index < arguments.count else { throw AgentCLIParseError.missingArgument }
                let rawValue = arguments[index]
                index += 1
                guard let value = Int(rawValue), (1...100).contains(value) else {
                    throw AgentCLIParseError.invalidInteger
                }
                weeklyPercent = value
            case "--help", "-h": positional.append("help")
            case let value where value.hasPrefix("-"): throw AgentCLIParseError.invalidFlag
            default: positional.append(argument)
            }
        }

        guard let family = positional.first else {
            return AgentCLICommand(operation: .help, options: AgentCLIOptions(json: json, confirm: confirm, dryRun: dryRun))
        }
        let tail = Array(positional.dropFirst())
        let operation: AgentCLIOperation
        switch family {
        case "help":
            guard tail.isEmpty else { throw AgentCLIParseError.invalidArgument }
            operation = .help
        case "status":
            guard tail.isEmpty else { throw AgentCLIParseError.invalidArgument }
            operation = .status
        case "accounts":
            guard let subcommand = tail.first else { throw AgentCLIParseError.missingArgument }
            let rest = Array(tail.dropFirst())
            switch subcommand {
            case "list": guard rest.isEmpty else { throw AgentCLIParseError.invalidArgument }; operation = .accountsList
            case "show": guard rest.count == 1 else { throw rest.isEmpty ? AgentCLIParseError.missingArgument : AgentCLIParseError.invalidArgument }; operation = .accountsShow(rest[0])
            case "import": guard rest.isEmpty else { throw AgentCLIParseError.invalidArgument }; operation = .accountsImport
            case "reconcile": guard rest.isEmpty else { throw AgentCLIParseError.invalidArgument }; operation = .accountsReconcile
            case "archive": guard rest.count == 1 else { throw rest.isEmpty ? AgentCLIParseError.missingArgument : AgentCLIParseError.invalidArgument }; operation = .accountArchive(rest[0])
            case "restore": guard rest.count == 1 else { throw rest.isEmpty ? AgentCLIParseError.missingArgument : AgentCLIParseError.invalidArgument }; operation = .accountRestore(rest[0])
            case "remove": guard rest.count == 1 else { throw rest.isEmpty ? AgentCLIParseError.missingArgument : AgentCLIParseError.invalidArgument }; operation = .accountRemove(rest[0])
            default: throw AgentCLIParseError.unknownCommand
            }
        case "account":
            guard let subcommand = tail.first else { throw AgentCLIParseError.missingArgument }
            let rest = Array(tail.dropFirst())
            switch subcommand {
            case "switch":
                guard rest.count == 1 else { throw rest.isEmpty ? AgentCLIParseError.missingArgument : AgentCLIParseError.invalidArgument }
                operation = .accountSwitch(rest[0])
            case "sticky":
                guard rest.count == 1 else { throw rest.isEmpty ? AgentCLIParseError.missingArgument : AgentCLIParseError.invalidArgument }
                operation = .accountSticky(rest[0], desired: accountMode)
            case "routing":
                if rest.count == 1, let accountMode {
                    operation = .accountRouting(rest[0], enabled: accountMode)
                    break
                }
                guard rest.count == 2, accountMode == nil else { throw rest.count < 2 ? AgentCLIParseError.missingArgument : AgentCLIParseError.invalidArgument }
                let first = rest[0].lowercased()
                let second = rest[1].lowercased()
                if ["enable", "on"].contains(first) {
                    operation = .accountRouting(rest[1], enabled: true)
                } else if ["disable", "off"].contains(first) {
                    operation = .accountRouting(rest[1], enabled: false)
                } else if ["enable", "on"].contains(second) {
                    operation = .accountRouting(rest[0], enabled: true)
                } else if ["disable", "off"].contains(second) {
                    operation = .accountRouting(rest[0], enabled: false)
                } else {
                    throw AgentCLIParseError.invalidArgument
                }
            case "usage-limit":
                guard let mode = rest.first else { throw AgentCLIParseError.missingArgument }
                let target = Array(rest.dropFirst())
                switch mode {
                case "show":
                    guard target.count == 1 else {
                        throw target.isEmpty ? AgentCLIParseError.missingArgument : AgentCLIParseError.invalidArgument
                    }
                    guard fiveHourPercent == nil, weeklyPercent == nil, accountMode == nil else {
                        throw AgentCLIParseError.unsupportedFlag
                    }
                    operation = .accountUsageLimitShow(target[0])
                case "set":
                    guard target.count == 1 else {
                        throw target.isEmpty ? AgentCLIParseError.missingArgument : AgentCLIParseError.invalidArgument
                    }
                    operation = .accountUsageLimitSet(
                        target[0],
                        fiveHour: fiveHourPercent,
                        weekly: weeklyPercent,
                        enabled: accountMode
                    )
                default:
                    throw AgentCLIParseError.unknownCommand
                }
            case "rank":
                guard rest.count == 2 else { throw rest.count < 2 ? AgentCLIParseError.missingArgument : AgentCLIParseError.invalidArgument }
                guard let rank = Int(rest[1]), rank > 0 else { throw AgentCLIParseError.invalidInteger }
                operation = .accountRank(rest[0], rank: rank)
            case "archive":
                guard rest.count == 1 else { throw rest.isEmpty ? AgentCLIParseError.missingArgument : AgentCLIParseError.invalidArgument }
                operation = .accountArchive(rest[0])
            case "restore":
                guard rest.count == 1 else { throw rest.isEmpty ? AgentCLIParseError.missingArgument : AgentCLIParseError.invalidArgument }
                operation = .accountRestore(rest[0])
            case "remove":
                guard rest.count == 1 else { throw rest.isEmpty ? AgentCLIParseError.missingArgument : AgentCLIParseError.invalidArgument }
                operation = .accountRemove(rest[0])
            default: throw AgentCLIParseError.unknownCommand
            }
        case "quota":
            guard tail.count == 1, tail[0] == "report" else { throw tail.isEmpty ? AgentCLIParseError.missingArgument : AgentCLIParseError.invalidArgument }
            operation = .quotaReport
        case "warmup":
            guard let subcommand = tail.first else { throw AgentCLIParseError.missingArgument }
            let rest = Array(tail.dropFirst())
            switch subcommand {
            case "all":
                guard rest.isEmpty else { throw AgentCLIParseError.invalidArgument }
                operation = .warmupAll
            case "account":
                guard rest.count == 1 else { throw rest.isEmpty ? AgentCLIParseError.missingArgument : AgentCLIParseError.invalidArgument }
                operation = .warmupAccount(rest[0])
            default:
                throw AgentCLIParseError.unknownCommand
            }
        case "reset":
            guard let subcommand = tail.first else { throw AgentCLIParseError.missingArgument }
            let rest = Array(tail.dropFirst())
            switch subcommand {
            case "status": guard rest.isEmpty else { throw AgentCLIParseError.invalidArgument }; operation = .resetStatus
            case "use": guard rest.count == 1 else { throw rest.isEmpty ? AgentCLIParseError.missingArgument : AgentCLIParseError.invalidArgument }; operation = .resetUse(rest[0])
            default: throw AgentCLIParseError.unknownCommand
            }
        case "routing":
            guard let subcommand = tail.first, tail.count == 1 else { throw tail.isEmpty ? AgentCLIParseError.missingArgument : AgentCLIParseError.invalidArgument }
            switch subcommand {
            case "get": operation = .routingGet
            case "enable": operation = .routingEnable
            case "disable": operation = .routingDisable
            case "repair": operation = .routingRepair
            default: throw AgentCLIParseError.unknownCommand
            }
        case "settings":
            guard let subcommand = tail.first else { throw AgentCLIParseError.missingArgument }
            let rest = Array(tail.dropFirst())
            switch subcommand {
            case "get":
                guard rest.count <= 1 else { throw AgentCLIParseError.invalidArgument }
                operation = .settingsGet(rest.first)
            case "set":
                guard rest.count == 2 else { throw rest.count < 2 ? AgentCLIParseError.missingArgument : AgentCLIParseError.invalidArgument }
                operation = .settingsSet(rest[0], rest[1])
            default: throw AgentCLIParseError.unknownCommand
            }
        default:
            throw AgentCLIParseError.unknownCommand
        }

        let options = AgentCLIOptions(json: json, confirm: confirm, dryRun: dryRun, accountMode: accountMode)
        if fiveHourPercent != nil || weeklyPercent != nil {
            guard case .accountUsageLimitSet = operation else {
                throw AgentCLIParseError.unsupportedFlag
            }
        }
        if usageLimitModeAliasUsed {
            if case .accountUsageLimitSet = operation {
                // `--on`/`--off` remain valid aliases for sticky and routing
                // controls, but usage-limit accepts only its documented flags.
                throw AgentCLIParseError.unsupportedFlag
            }
        }
        try validateOptions(options, operation: operation)
        return AgentCLICommand(operation: operation, options: options)
    }

    private static func validateOptions(_ options: AgentCLIOptions, operation: AgentCLIOperation) throws {
        let supportsConfirm: Bool
        let supportsDryRun: Bool
        switch operation {
        case .accountArchive, .accountRemove, .resetUse, .warmupAll, .warmupAccount, .accountsReconcile,
             .accountUsageLimitSet:
            supportsConfirm = true
            supportsDryRun = true
        case .accountSwitch, .accountSticky, .accountRouting, .accountRank, .accountRestore,
             .routingEnable, .routingDisable, .routingRepair, .settingsSet:
            supportsConfirm = false
            supportsDryRun = true
        default:
            supportsConfirm = false
            supportsDryRun = false
        }
        if options.confirm && !supportsConfirm { throw AgentCLIParseError.unsupportedFlag }
        if options.dryRun && !supportsDryRun { throw AgentCLIParseError.unsupportedFlag }
        if options.accountMode != nil {
            switch operation {
            case .accountSticky, .accountRouting, .accountUsageLimitSet: break
            default: throw AgentCLIParseError.unsupportedFlag
            }
        }
    }
}

// MARK: - Sanitized account projection

private struct AgentAccountEntry: Sendable {
    let account: Account
    let reference: String
    let number: Int
    let displayAlias: String?
}

private struct AgentAccountRoster: Sendable {
    let entries: [AgentAccountEntry]
    let byReference: [String: AgentAccountEntry]
    let bySafeAlias: [String: AgentAccountEntry]

    func resolve(_ input: String) -> AgentAccountEntry? {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let entry = byReference[normalized] { return entry }
        // Exact aliases are accepted only if they passed the same safety filter
        // used for presentation.  This prevents a token-like alias from becoming
        // an echo channel in a command error or response.
        guard let entry = bySafeAlias[normalized], entry.displayAlias == input else { return nil }
        return entry
    }
}

public enum AgentSanitizer {
    /// Exposed for focused tests and other local agent integrations.  It never
    /// returns a credential-bearing value and uses generic references when an
    /// alias resembles a private identity field.
    public static func safeAlias(_ alias: String, privateValues: Set<String>) -> String? {
        let candidate = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(candidate.unicodeScalars.count),
              candidate.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || [" ", ".", "_", "+", "-"].contains(String(scalar))
              }) else { return nil }
        let normalized = candidate.lowercased()
        let values = Set(privateValues.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        if values.contains(normalized) { return nil }
        if normalized.count >= 6, values.contains(where: { normalized.contains($0) }) { return nil }
        let forbidden = ["email", "token", "accountid", "account-id", "account_id", "creditid", "credit-id", "credit_id", "authorization", "bearer"]
        if forbidden.contains(where: { normalized.contains($0) }) { return nil }
        return candidate
    }
}

// MARK: - Agent command execution

/// AgentCLI is intentionally a thin adapter.  Account mutations, routing,
/// quota reset and warm-up work all stay in AccountStore/AppEngine/services;
/// this type only parses inputs and projects their results into a safe envelope.
public struct AgentCLI: Sendable {
    private let store: AccountStore
    private let settingsStore: SettingsStore
    private let usageService: any UsageFetching
    private let resetService: any QuotaResetServing
    private let warmupService: QuotaWarmupService
    private let configManager: CodexConfigManager
    private let supportDir: URL
    private let engine: AppEngine
    private let runtimeURLProvider: @Sendable () -> URL?

    public init(
        store: AccountStore = AccountStore(),
        settingsStore: SettingsStore = SettingsStore(),
        usageService: any UsageFetching = UsageClient(),
        resetService: any QuotaResetServing = QuotaResetClient(),
        warmupService: QuotaWarmupService = QuotaWarmupService(),
        configManager: CodexConfigManager = CodexConfigManager(),
        supportDir: URL = AppPaths.supportDir(),
        runtimeURLProvider: @escaping @Sendable () -> URL? = RuntimeHandoff.readProxyURL
    ) {
        self.store = store
        self.settingsStore = settingsStore
        self.usageService = usageService
        self.resetService = resetService
        self.warmupService = warmupService
        self.configManager = configManager
        self.supportDir = supportDir
        self.runtimeURLProvider = runtimeURLProvider
        let coordinator = QuotaResetCoordinator(
            accountStore: store,
            settings: { await settingsStore.get() },
            resetService: resetService,
            usageService: usageService,
            pendingRecordURL: supportDir.appendingPathComponent("pending-quota-reset.json")
        )
        self.engine = AppEngine(
            store: store,
            settingsStore: settingsStore,
            usage: usageService,
            configManager: configManager,
            warmupService: warmupService,
            quotaResetCoordinator: coordinator,
            taskStore: TaskStore(url: supportDir.appendingPathComponent("tasks.json")),
            supportDir: supportDir
        )
    }

    public func run(_ arguments: [String]) async -> AgentCLIResult {
        let command: AgentCLICommand
        do {
            command = try AgentCLIParser.parse(arguments)
        } catch let error as AgentCLIParseError {
            let envelope = AgentCLIEnvelope.failure(
                command: "agent",
                code: "usage",
                message: error.errorDescription ?? "invalid agent command"
            )
            return AgentCLIResult(envelope: envelope, exitCode: .usage)
        } catch is CancellationError {
            return cancelled(command: "agent")
        } catch {
            return AgentCLIResult(
                envelope: .failure(command: "agent", code: "software_error", message: "agent command could not be parsed"),
                exitCode: .software
            )
        }

        if case .help = command.operation {
            return AgentCLIResult(
                envelope: .success(command: command.canonicalName, data: .object(["help": .string(Self.helpText)])),
                exitCode: .ok
            )
        }
        do {
            return try await execute(command)
        } catch is CancellationError {
            return cancelled(command: command.canonicalName)
        } catch {
            return AgentCLIResult(
                envelope: .failure(command: command.canonicalName, code: "software_error", message: "agent command failed"),
                exitCode: .software
            )
        }
    }

    public static let helpText = """
    agent — safe machine-readable CodexSwap control
      status --json
      accounts list|show <alias-or-ref>|import|reconcile --json
      account switch|sticky|routing|usage-limit|rank|archive|restore|remove ... [--json]
      account usage-limit show <alias-or-ref> --json
      account usage-limit set <alias-or-ref> --five-hour N --weekly N [--enable|--disable] [--confirm|--dry-run] --json
      quota report --json
      warmup all --json --confirm
      warmup account <alias-or-ref> --json --confirm
      reset status --json; reset use <alias-or-ref> --json --confirm
      routing get|enable|disable|repair --json
      settings get|set <allowlisted-key> <typed-value> --json
    """

    private func execute(_ command: AgentCLICommand) async throws -> AgentCLIResult {
        switch command.operation {
        case .help:
            return AgentCLIResult(envelope: .success(command: command.canonicalName), exitCode: .ok)
        case .status:
            return await status(command)
        case .accountsList:
            return await accountsList(command)
        case .accountsShow(let target):
            return await accountsShow(target: target, command: command)
        case .accountsImport:
            return await accountsImport(command)
        case .accountsReconcile:
            return await accountsReconcile(command)
        case .accountSwitch(let target):
            return await accountSwitch(target: target, command: command)
        case .accountSticky(let target, let desired):
            return await accountSticky(target: target, desired: desired, command: command)
        case .accountRouting(let target, let enabled):
            return await accountRouting(target: target, enabled: enabled, command: command)
        case .accountUsageLimitShow(let target):
            return await accountUsageLimitShow(target: target, command: command)
        case .accountUsageLimitSet(let target, let fiveHour, let weekly, let enabled):
            return await accountUsageLimitSet(
                target: target,
                fiveHour: fiveHour,
                weekly: weekly,
                enabled: enabled,
                command: command
            )
        case .accountRank(let target, let rank):
            return await accountRank(target: target, rank: rank, command: command)
        case .accountArchive(let target):
            return await accountArchive(target: target, command: command)
        case .accountRestore(let target):
            return await accountRestore(target: target, command: command)
        case .accountRemove(let target):
            return await accountRemove(target: target, command: command)
        case .quotaReport:
            return try await quotaReport(command)
        case .warmupAll:
            return await warmupAll(command)
        case .warmupAccount(let target):
            return await warmupAccount(target: target, command: command)
        case .resetStatus:
            return await resetStatus(command)
        case .resetUse(let target):
            return await resetUse(target: target, command: command)
        case .routingGet:
            return await routingGet(command)
        case .routingEnable:
            return await routingSet(enabled: true, command: command)
        case .routingDisable:
            return await routingSet(enabled: false, command: command)
        case .routingRepair:
            return await routingRepair(command)
        case .settingsGet(let key):
            return await settingsGet(key: key, command: command)
        case .settingsSet(let key, let rawValue):
            return await settingsSet(key: key, rawValue: rawValue, command: command)
        }
    }

    private func cancelled(command: String) -> AgentCLIResult {
        AgentCLIResult(
            envelope: .failure(command: command, code: "cancelled", message: "agent command cancelled"),
            exitCode: .cancelled
        )
    }

    private func roster() async -> AgentAccountRoster {
        let active = await store.activeAccounts()
        let archived = await store.archivedAccounts()
        let accounts = active + archived
        let privateValues = Set(accounts.flatMap { [$0.email, $0.accountID, $0.accessToken, $0.refreshToken, $0.idToken] })
        var usedAliases = Set<String>()
        var entries: [AgentAccountEntry] = []
        entries.reserveCapacity(accounts.count)
        for (index, account) in accounts.enumerated() {
            let reference = Self.stableReference(for: account)
            let candidate = AgentSanitizer.safeAlias(account.alias, privateValues: privateValues)
            let normalized = candidate?.lowercased()
            let displayAlias: String?
            if let candidate, let normalized,
               !Self.looksLikeReference(normalized),
               !usedAliases.contains(normalized) {
                usedAliases.insert(normalized)
                displayAlias = candidate
            } else {
                displayAlias = nil
            }
            entries.append(AgentAccountEntry(account: account, reference: reference, number: index + 1, displayAlias: displayAlias))
        }
        var byReference: [String: AgentAccountEntry] = [:]
        var bySafeAlias: [String: AgentAccountEntry] = [:]
        for entry in entries {
            byReference[entry.reference.lowercased()] = entry
            if let displayAlias = entry.displayAlias {
                bySafeAlias[displayAlias.lowercased()] = entry
            }
        }
        return AgentAccountRoster(entries: entries, byReference: byReference, bySafeAlias: bySafeAlias)
    }

    private static func stableReference(for account: Account) -> String {
        // telemetryID is a local random identifier, not an upstream account ID.
        // Never expose even a prefix of it: refs are one-way, deterministic
        // handles that remain stable across rank changes and CLI processes.
        let domainSeparated = Data("CodexSwap agent account ref v1:\(account.telemetryID.uuidString.lowercased())".utf8)
        let digest = SHA256.hash(data: domainSeparated)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "acct-\(String(hex.prefix(16)))"
    }

    private static func looksLikeReference(_ value: String) -> Bool {
        let parts = value.split(separator: " ", omittingEmptySubsequences: true)
        return parts.count == 2 && parts[0].lowercased() == "account" && Int(parts[1]) != nil
    }

    private func accountView(_ entry: AgentAccountEntry, activeAlias: String? = nil, stickyAlias: String? = nil, draining: Set<String> = []) -> AgentCLIJSONValue {
        let privateValues = Set([entry.account.email, entry.account.accountID, entry.account.accessToken, entry.account.refreshToken, entry.account.idToken])
        var object: [String: AgentCLIJSONValue] = [
            "ref": .string(entry.reference),
            "number": .integer(entry.number),
            "rank": .integer(max(0, entry.account.priority)),
            "active": .bool(entry.account.alias == activeAlias),
            "archived": .bool(entry.account.isArchived),
            "routingEnabled": .bool(entry.account.routingEnabled),
            "needsLogin": .bool(entry.account.needsLogin),
            "draining": .bool(draining.contains(entry.account.alias)),
        ]
        // Unsafe aliases are intentionally replaced with a numbered display
        // label. The label is presentation-only; mutations resolve only the
        // opaque `ref` (or an exact safe alias), never `Account N`.
        object["alias"] = .string(entry.displayAlias ?? "Account \(entry.number)")
        if let cooldown = entry.account.cooldownUntil(now: Date()) {
            object["cooldownUntil"] = .string(Self.iso8601(cooldown))
        }
        let windows = entry.account.usage.enumerated().map { index, window -> AgentCLIJSONValue in
            var value: [String: AgentCLIJSONValue] = [
                "label": .string(Self.safeWindowLabel(window.label, fallbackIndex: index + 1, privateValues: privateValues)),
                "usedPercent": .integer(min(max(window.usedPercent, 0), 100)),
                "windowSeconds": .integer(max(0, window.windowSeconds)),
            ]
            if let resetAt = window.resetAt { value["resetAt"] = .string(Self.iso8601(resetAt)) }
            return .object(value)
        }
        object["usage"] = .array(windows)
        object["sticky"] = .bool(entry.account.alias == stickyAlias)
        return .object(object)
    }

    private static func safeWindowLabel(_ raw: String, fallbackIndex: Int, privateValues: Set<String> = []) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        let forbidden = ["email", "token", "accountid", "account-id", "account_id", "authorization", "bearer"]
        let normalizedPrivateValues = Set(privateValues.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        guard (1...32).contains(trimmed.unicodeScalars.count),
              trimmed.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || [" ", ".", "_", "+", "-"].contains(String($0)) }),
              !normalizedPrivateValues.contains(normalized),
              !(normalized.count >= 6 && normalizedPrivateValues.contains(where: { normalized.contains($0) })),
              !forbidden.contains(where: { normalized.contains($0) }) else {
            return "Window \(fallbackIndex)"
        }
        return trimmed
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func isSyntacticallyUsableLoopback(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(), ["127.0.0.1", "localhost", "::1"].contains(host),
              let port = url.port, (1...65_535).contains(port),
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return false }
        return true
    }

    private static func isUsableLoopback(_ url: URL?) -> Bool {
        guard isSyntacticallyUsableLoopback(url),
              let host = url?.host?.lowercased(),
              let port = url?.port else { return false }
        return isLoopbackListenerReachable(host: host, port: port)
    }

    private static func isLoopbackListenerReachable(host: String, port: Int) -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        if host == "::1" {
            let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
            guard descriptor >= 0 else { return false }
            defer { _ = close(descriptor) }
            _ = withUnsafePointer(to: &timeout) { pointer in
                setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
            }
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(UInt16(port).bigEndian)
            guard inet_pton(AF_INET6, host, &address.sin6_addr) == 1 else { return false }
            return withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
                }
            }
        }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { _ = close(descriptor) }
        _ = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        let addressValue = host == "localhost" ? "127.0.0.1" : host
        guard inet_pton(AF_INET, addressValue, &address.sin_addr) == 1 else { return false }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        #else
        return false
        #endif
    }

    /// Resolve a live listener without trusting a stale handoff file. When the
    /// app has not written `proxy.url` (for example during an upgrade), probe the
    /// configured loopback port before handing it to a mutating operation.
    private func runtimeURLCandidate(settings: Settings? = nil) async -> URL? {
        if let handoff = runtimeURLProvider(), Self.isSyntacticallyUsableLoopback(handoff), Self.isUsableLoopback(handoff) {
            return handoff
        }
        let resolved: Settings
        if let settings {
            resolved = settings
        } else {
            resolved = await settingsStore.get()
        }
        return URL(string: "http://127.0.0.1:\(resolved.proxyPort)")
    }

    private static func routingValue(_ state: CodexRoutingState) -> AgentCLIJSONValue {
        switch state {
        case .disabled: return .string("disabled")
        case .enabled: return .string("enabled")
        case .needsRepair: return .string("needsRepair")
        }
    }

    private func status(_ command: AgentCLICommand) async -> AgentCLIResult {
        let settings = await settingsStore.get()
        await store.setStrategy(settings.rotationStrategy)
        let snapshot = await engine.snapshot()
        let accountRoster = await roster()
        let activeCount = accountRoster.entries.filter { !$0.account.isArchived }.count
        let archivedCount = accountRoster.entries.filter { $0.account.isArchived }.count
        let runtimeURL = await runtimeURLCandidate()
        let proxyAvailable = Self.isUsableLoopback(runtimeURL)
        let activeRef = snapshot.activeAlias.flatMap { alias in accountRoster.entries.first(where: { $0.account.alias == alias })?.reference }
        let stickyRef = snapshot.stickyAlias.flatMap { alias in accountRoster.entries.first(where: { $0.account.alias == alias })?.reference }
        let drainingRefs = snapshot.drainingAliases.compactMap { alias in accountRoster.entries.first(where: { $0.account.alias == alias })?.reference }.sorted()
        var data: [String: AgentCLIJSONValue] = [
            "proxy": .object([
                "available": .bool(proxyAvailable),
                "port": .integer(runtimeURL?.port ?? 0),
            ]),
            "routing": Self.routingValue(snapshot.routingState),
            "strategy": .string(snapshot.strategy.rawValue),
            "activeRef": activeRef.map(AgentCLIJSONValue.string) ?? .null,
            "stickyRef": stickyRef.map(AgentCLIJSONValue.string) ?? .null,
            "drainingRefs": .array(drainingRefs.map(AgentCLIJSONValue.string)),
            "accounts": .object([
                "active": .integer(activeCount),
                "archived": .integer(archivedCount),
                "total": .integer(accountRoster.entries.count),
            ]),
            "warmupInProgress": .bool(snapshot.warmupInProgress),
        ]
        if let summary = snapshot.warmupSummary {
            data["warmup"] = .object([
                "warmed": .integer(summary.warmed.count),
                "attempted": .integer(summary.attempted.count),
                "skipped": .integer(summary.skipped.count),
                "failed": .integer(summary.failed.count),
                "finishedAt": .string(Self.iso8601(summary.finishedAt)),
            ])
        }
        var warnings: [String] = []
        if !proxyAvailable { warnings.append("proxy_unavailable") }
        return AgentCLIResult(envelope: .success(command: command.canonicalName, data: .object(data), warnings: warnings), exitCode: .ok)
    }

    private func accountsList(_ command: AgentCLICommand) async -> AgentCLIResult {
        let accountRoster = await roster()
        let active = await store.activeAlias()
        let sticky = await store.stickyAlias()
        let draining = await store.currentDrainingAliases()
        let accounts = accountRoster.entries.map { accountView($0, activeAlias: active, stickyAlias: sticky, draining: draining) }
        let data: AgentCLIJSONValue = .object([
            "accounts": .array(accounts),
            "count": .integer(accounts.count),
        ])
        return AgentCLIResult(envelope: .success(command: command.canonicalName, data: data), exitCode: .ok)
    }

    private func accountsShow(target: String, command: AgentCLICommand) async -> AgentCLIResult {
        let accountRoster = await roster()
        guard let entry = accountRoster.resolve(target) else { return missingAccount(command: command.canonicalName) }
        let data = accountView(entry, activeAlias: await store.activeAlias(), stickyAlias: await store.stickyAlias(), draining: await store.currentDrainingAliases())
        return AgentCLIResult(envelope: .success(command: command.canonicalName, data: data), exitCode: .ok)
    }

    private func accountsImport(_ command: AgentCLICommand) async -> AgentCLIResult {
        let before = (await store.all()).count
        await engine.importAccounts()
        let after = (await store.all()).count
        let data: AgentCLIJSONValue = .object([
            "before": .integer(before),
            "after": .integer(after),
            "added": .integer(max(0, after - before)),
        ])
        return AgentCLIResult(envelope: .success(command: command.canonicalName, data: data), exitCode: .ok)
    }

    private func accountsReconcile(_ command: AgentCLICommand) async -> AgentCLIResult {
        let beforeRoster = await roster()
        let before = beforeRoster.entries.count
        let available = CodexBarBridge.isPresent()
        if !command.options.confirm && !command.options.dryRun {
            return confirmationRequired(command: command.canonicalName, action: "reconcile managed accounts")
        }
        if command.options.dryRun {
            var warnings: [String] = []
            var affectedRefs: [String] = []
            var projectedAfter = before
            var impactKnown = true
            if available {
                // Reconcile only removes managed records whose provider ID has
                // disappeared. Those refs are already stable and safe to show.
                let presentIDs = CodexBarBridge.rosterAccountIDs()
                let removed = beforeRoster.entries.filter { entry in
                    entry.account.managedHomePath != nil && !presentIDs.contains(entry.account.accountID)
                }
                affectedRefs = removed.map(\.reference).sorted()
                projectedAfter -= removed.count

                // New managed records receive a fresh telemetry UUID during
                // the real upsert, so their eventual opaque refs cannot be
                // predicted without mutating the store. Do not claim an empty
                // impact list in that case; require confirmation on apply.
                let knownAccountIDs = Set(beforeRoster.entries.map(\.account.accountID).filter { !$0.isEmpty })
                let imported = AccountImporter.codexBarAccounts()
                let unknownAdds = imported.filter { account in
                    account.accountID.isEmpty || !knownAccountIDs.contains(account.accountID)
                }
                projectedAfter += unknownAdds.count
                if !unknownAdds.isEmpty {
                    impactKnown = false
                    warnings.append("reconcile_impact_unknown")
                }
            } else {
                // syncCodexBar() is a documented no-op when CodexBar is absent,
                // so this preview is known to leave the roster unchanged.
                warnings.append("codexbar_unavailable")
            }
            let data: AgentCLIJSONValue = .object([
                "before": .integer(before),
                "after": .integer(max(0, projectedAfter)),
                "removedOrAdded": .integer(projectedAfter - before),
                "dryRun": .bool(true),
                "impactKnown": .bool(impactKnown),
                "affectedRefs": .array(affectedRefs.map(AgentCLIJSONValue.string)),
                "confirmationRequired": .bool(!impactKnown),
            ])
            return AgentCLIResult(envelope: .success(command: command.canonicalName, data: data, warnings: warnings), exitCode: .ok)
        }
        await engine.syncCodexBar()
        let after = (await store.all()).count
        let afterRefs = Set((await roster()).entries.map(\.reference))
        let beforeRefs = Set(beforeRoster.entries.map(\.reference))
        let affectedRefs = (beforeRefs.symmetricDifference(afterRefs)).sorted()
        var warnings: [String] = []
        if !available { warnings.append("codexbar_unavailable") }
        let data: AgentCLIJSONValue = .object([
            "before": .integer(before),
            "after": .integer(after),
            "removedOrAdded": .integer(after - before),
            "affectedRefs": .array(affectedRefs.map(AgentCLIJSONValue.string)),
        ])
        return AgentCLIResult(envelope: .success(command: command.canonicalName, data: data, warnings: warnings), exitCode: .ok)
    }

    private func missingAccount(command: String) -> AgentCLIResult {
        AgentCLIResult(
            envelope: .failure(command: command, code: "account_not_found", message: "account reference or safe alias not found"),
            exitCode: .data
        )
    }

    private func accountSwitch(target: String, command: AgentCLICommand) async -> AgentCLIResult {
        let accountRoster = await roster()
        guard let entry = accountRoster.resolve(target), !entry.account.isArchived, entry.account.routingEnabled else { return missingAccount(command: command.canonicalName) }
        guard !entry.account.isUsageLimitReached else {
            return AgentCLIResult(
                envelope: .failure(
                    command: command.canonicalName,
                    code: "usage_limit_reached",
                    message: "account usage limit reached"
                ),
                exitCode: .data
            )
        }
        if command.options.dryRun {
            return AgentCLIResult(envelope: .success(command: command.canonicalName, data: .object(["wouldSwitchTo": .string(entry.reference)])), exitCode: .ok)
        }
        await engine.switchTo(entry.account.alias)
        guard await store.activeAlias() == entry.account.alias else {
            let latest = await store.account(entry.account.alias)
            if latest?.isUsageLimitReached == true {
                return AgentCLIResult(
                    envelope: .failure(
                        command: command.canonicalName,
                        code: "usage_limit_reached",
                        message: "account usage limit reached"
                    ),
                    exitCode: .data
                )
            }
            return AgentCLIResult(
                envelope: .failure(
                    command: command.canonicalName,
                    code: "account_not_eligible",
                    message: "account could not become active"
                ),
                exitCode: .data
            )
        }
        let data = accountView((await roster()).entries.first(where: { $0.account.alias == entry.account.alias }) ?? entry, activeAlias: await store.activeAlias(), stickyAlias: await store.stickyAlias(), draining: await store.currentDrainingAliases())
        return AgentCLIResult(envelope: .success(command: command.canonicalName, data: data), exitCode: .ok)
    }

    private func accountUsageLimitShow(target: String, command: AgentCLICommand) async -> AgentCLIResult {
        let accountRoster = await roster()
        guard let entry = accountRoster.resolve(target) else { return missingAccount(command: command.canonicalName) }
        let data = usageLimitView(for: entry.account, reference: entry.reference)
        return AgentCLIResult(envelope: .success(command: command.canonicalName, data: data), exitCode: .ok)
    }

    private func accountUsageLimitSet(
        target: String,
        fiveHour: Int?,
        weekly: Int?,
        enabled: Bool?,
        command: AgentCLICommand
    ) async -> AgentCLIResult {
        let accountRoster = await roster()
        guard let entry = accountRoster.resolve(target), !entry.account.isArchived else {
            return missingAccount(command: command.canonicalName)
        }

        let existing = entry.account.usageLimitSettings
        let proposedEnabled = enabled ?? existing.enabled
        let isNewSet = !existing.enabled && (fiveHour != nil || weekly != nil)
        if (enabled == true || isNewSet) && (fiveHour == nil || weekly == nil) {
            return AgentCLIResult(
                envelope: .failure(
                    command: command.canonicalName,
                    code: "usage_limit_values_required",
                    message: "both --five-hour and --weekly are required when enabling a usage limit"
                ),
                exitCode: .usage
            )
        }

        let proposed = AccountUsageLimitSettings(
            enabled: proposedEnabled,
            fiveHourPercent: fiveHour ?? existing.fiveHourPercent,
            weeklyPercent: weekly ?? existing.weeklyPercent
        )
        var projected = entry.account
        projected.usageLimitSettings = proposed
        let stickyAlias = await store.stickyAlias()
        let stickyLimitOverride = await store.stickyUsageLimitOverride()
        let stickyOverride = stickyAlias == entry.account.alias && stickyLimitOverride
        let activeAlias = await store.activeAlias()
        let immediatelyPausesCurrent = activeAlias == entry.account.alias
            && !stickyOverride
            && !entry.account.isUsageLimitReached
            && projected.isUsageLimitReached

        if command.options.dryRun {
            return AgentCLIResult(
                envelope: .success(
                    command: command.canonicalName,
                    data: usageLimitView(
                        for: projected,
                        reference: entry.reference,
                        persisted: false,
                        dryRun: true,
                        confirmationRequired: immediatelyPausesCurrent
                    )
                ),
                exitCode: .ok
            )
        }
        if immediatelyPausesCurrent && !command.options.confirm {
            return AgentCLIResult(
                envelope: .failure(
                    command: command.canonicalName,
                    code: "confirmation_required",
                    message: "--confirm is required to apply a usage limit that pauses the active account"
                ),
                exitCode: .usage
            )
        }

        guard let updated = await store.setUsageLimitSettings(entry.account.alias, settings: proposed) else {
            return missingAccount(command: command.canonicalName)
        }
        return AgentCLIResult(
            envelope: .success(
                command: command.canonicalName,
                data: usageLimitView(
                    for: updated,
                    reference: entry.reference,
                    persisted: true,
                    dryRun: false,
                    confirmationRequired: false
                )
            ),
            exitCode: .ok
        )
    }

    private func usageLimitView(
        for account: Account,
        reference: String,
        persisted: Bool? = nil,
        dryRun: Bool? = nil,
        confirmationRequired: Bool? = nil
    ) -> AgentCLIJSONValue {
        var value: [String: AgentCLIJSONValue] = [
            "ref": .string(reference),
            "usageLimit": .object([
                "enabled": .bool(account.usageLimitSettings.enabled),
                "fiveHourPercent": .integer(account.usageLimitSettings.fiveHourPercent),
                "weeklyPercent": .integer(account.usageLimitSettings.weeklyPercent),
            ]),
        ]
        let reached = [AccountUsageLimitWindow.fiveHour, .weekly].filter {
            account.usageLimitReachedWindows.contains($0)
        }
        value["pausedWindows"] = .array(reached.map { .string($0.rawValue) })
        value["pausedReason"] = reached.isEmpty ? .null : .string("usage_limit_reached")
        if let persisted { value["persisted"] = .bool(persisted) }
        if let dryRun { value["dryRun"] = .bool(dryRun) }
        if let confirmationRequired { value["confirmationRequired"] = .bool(confirmationRequired) }
        return .object(value)
    }

    private func accountSticky(target: String, desired: Bool?, command: AgentCLICommand) async -> AgentCLIResult {
        let accountRoster = await roster()
        guard let entry = accountRoster.resolve(target) else { return missingAccount(command: command.canonicalName) }
        if command.options.dryRun {
            let currentlySticky = await store.stickyAlias() == entry.account.alias
            let next = desired ?? !currentlySticky
            return AgentCLIResult(envelope: .success(command: command.canonicalName, data: .object(["wouldSetSticky": .bool(next), "ref": .string(entry.reference)])), exitCode: .ok)
        }
        let wasSticky = await store.stickyAlias() == entry.account.alias
        if let desired {
            if desired != wasSticky {
                await engine.toggleStickyAccount(entry.account.alias)
            }
        } else {
            await engine.toggleStickyAccount(entry.account.alias)
        }
        let isSticky = await store.stickyAlias() == entry.account.alias
        guard wasSticky != isSticky || wasSticky else {
            return AgentCLIResult(envelope: .failure(command: command.canonicalName, code: "account_not_eligible", message: "account is not eligible for sticky routing"), exitCode: .data)
        }
        return AgentCLIResult(envelope: .success(command: command.canonicalName, data: .object(["ref": .string(entry.reference), "sticky": .bool(isSticky)])), exitCode: .ok)
    }

    private func accountRouting(target: String, enabled: Bool, command: AgentCLICommand) async -> AgentCLIResult {
        let accountRoster = await roster()
        guard let entry = accountRoster.resolve(target), !entry.account.isArchived else { return missingAccount(command: command.canonicalName) }
        if command.options.dryRun {
            return AgentCLIResult(envelope: .success(command: command.canonicalName, data: .object(["ref": .string(entry.reference), "wouldEnable": .bool(enabled)])), exitCode: .ok)
        }
        await engine.setAccountRouting(entry.account.alias, enabled: enabled)
        let refreshed = (await roster()).entries.first(where: { $0.account.alias == entry.account.alias }) ?? entry
        return AgentCLIResult(envelope: .success(command: command.canonicalName, data: accountView(refreshed, activeAlias: await store.activeAlias(), stickyAlias: await store.stickyAlias(), draining: await store.currentDrainingAliases())), exitCode: .ok)
    }

    private func accountRank(target: String, rank: Int, command: AgentCLICommand) async -> AgentCLIResult {
        let accountRoster = await roster()
        guard let entry = accountRoster.resolve(target), !entry.account.isArchived else { return missingAccount(command: command.canonicalName) }
        let active = accountRoster.entries.filter { !$0.account.isArchived }
        guard rank <= active.count else {
            return AgentCLIResult(envelope: .failure(command: command.canonicalName, code: "invalid_rank", message: "rank is outside the active account range"), exitCode: .data)
        }
        if command.options.dryRun {
            return AgentCLIResult(envelope: .success(command: command.canonicalName, data: .object(["ref": .string(entry.reference), "currentRank": .integer(entry.account.priority), "wouldRank": .integer(rank)])), exitCode: .ok)
        }
        await engine.reorderRank(entry.account.alias, toIndex: rank - 1)
        let refreshed = (await roster()).entries.first(where: { $0.account.alias == entry.account.alias }) ?? entry
        return AgentCLIResult(envelope: .success(command: command.canonicalName, data: accountView(refreshed, activeAlias: await store.activeAlias(), stickyAlias: await store.stickyAlias(), draining: await store.currentDrainingAliases())), exitCode: .ok)
    }

    private func accountArchive(target: String, command: AgentCLICommand) async -> AgentCLIResult {
        let accountRoster = await roster()
        guard let entry = accountRoster.resolve(target) else { return missingAccount(command: command.canonicalName) }
        if !command.options.confirm && !command.options.dryRun {
            return confirmationRequired(command: command.canonicalName, action: "archive")
        }
        if command.options.dryRun {
            return AgentCLIResult(envelope: .success(command: command.canonicalName, data: .object(["ref": .string(entry.reference), "wouldArchive": .bool(!entry.account.isArchived)])), exitCode: .ok)
        }
        switch await engine.archiveAccount(alias: entry.account.alias, confirmed: command.options.confirm) {
        case .archived(let archived):
            let refreshed = (await roster()).entries.first(where: { $0.account.alias == archived.alias }) ?? entry
            return AgentCLIResult(envelope: .success(command: command.canonicalName, data: accountView(refreshed, activeAlias: await store.activeAlias(), stickyAlias: await store.stickyAlias(), draining: await store.currentDrainingAliases())), exitCode: .ok)
        case .confirmationRequired:
            return confirmationRequired(command: command.canonicalName, action: "archive")
        case .accountUnavailable:
            return missingAccount(command: command.canonicalName)
        }
    }

    private func accountRestore(target: String, command: AgentCLICommand) async -> AgentCLIResult {
        let accountRoster = await roster()
        guard let entry = accountRoster.resolve(target) else { return missingAccount(command: command.canonicalName) }
        if command.options.dryRun {
            return AgentCLIResult(envelope: .success(command: command.canonicalName, data: .object(["ref": .string(entry.reference), "wouldRestore": .bool(entry.account.isArchived)])), exitCode: .ok)
        }
        guard let restored = await engine.restoreAccount(alias: entry.account.alias) else { return missingAccount(command: command.canonicalName) }
        let refreshed = (await roster()).entries.first(where: { $0.account.alias == restored.alias }) ?? entry
        return AgentCLIResult(envelope: .success(command: command.canonicalName, data: accountView(refreshed, activeAlias: await store.activeAlias(), stickyAlias: await store.stickyAlias(), draining: await store.currentDrainingAliases())), exitCode: .ok)
    }

    private func accountRemove(target: String, command: AgentCLICommand) async -> AgentCLIResult {
        let accountRoster = await roster()
        guard let entry = accountRoster.resolve(target) else { return missingAccount(command: command.canonicalName) }
        if !command.options.confirm && !command.options.dryRun {
            return confirmationRequired(command: command.canonicalName, action: "remove")
        }
        if command.options.dryRun {
            return AgentCLIResult(envelope: .success(command: command.canonicalName, data: .object(["ref": .string(entry.reference), "wouldRemove": .bool(true)])), exitCode: .ok)
        }
        await engine.remove(entry.account.alias)
        guard await store.account(entry.account.alias) == nil else {
            return AgentCLIResult(envelope: .failure(command: command.canonicalName, code: "remove_failed", message: "account could not be removed"), exitCode: .software)
        }
        return AgentCLIResult(envelope: .success(command: command.canonicalName, data: .object(["ref": .string(entry.reference), "removed": .bool(true)])), exitCode: .ok)
    }

    private func confirmationRequired(command: String, action: String) -> AgentCLIResult {
        AgentCLIResult(
            envelope: .failure(command: command, code: "confirmation_required", message: "--confirm is required to (action) an account"),
            exitCode: .usage
        )
    }

    private func quotaReport(_ command: AgentCLICommand) async throws -> AgentCLIResult {
        let accounts = await store.activeAccounts()
        let service = QuotaReportService(usageService: usageService, resetService: resetService)
        let activeAlias = await store.activeAlias()
        let report = try await service.fetch(accounts: accounts, activeAlias: activeAlias)
        let privateValues = Set(accounts.flatMap { [$0.email, $0.accountID, $0.accessToken, $0.refreshToken, $0.idToken] })
        let reportOrder = accounts.sorted { lhs, rhs in
            let lhsActive = activeAlias.map { lhs.alias.caseInsensitiveCompare($0) == .orderedSame } ?? false
            let rhsActive = activeAlias.map { rhs.alias.caseInsensitiveCompare($0) == .orderedSame } ?? false
            if lhsActive != rhsActive { return lhsActive }
            let l = lhs.alias.lowercased(); let r = rhs.alias.lowercased()
            if l != r { return l < r }
            return lhs.alias < rhs.alias
        }
        let rosterEntries = await roster().entries
        let reportRefs = reportOrder.compactMap { account in rosterEntries.first(where: { $0.account.alias == account.alias })?.reference }
        let data = sanitizedQuotaData(report, privateValues: privateValues, refs: reportRefs)
        return AgentCLIResult(envelope: .success(command: command.canonicalName, data: data), exitCode: .ok)
    }

    private func sanitizedQuotaData(_ report: CodexQuotaReport, privateValues: Set<String>, refs: [String]) -> AgentCLIJSONValue {
        var usedAliases = Set<String>()
        var genericIndex = 1
        let accountValues = report.accounts.enumerated().map { index, account -> AgentCLIJSONValue in
            let candidate = AgentSanitizer.safeAlias(account.alias, privateValues: privateValues)
            let alias: String
            if let candidate, !usedAliases.contains(candidate.lowercased()), !Self.looksLikeReference(candidate.lowercased()) {
                alias = candidate
                usedAliases.insert(candidate.lowercased())
            } else {
                while usedAliases.contains("account \(genericIndex)") { genericIndex += 1 }
                alias = "Account \(genericIndex)"
                genericIndex += 1
                usedAliases.insert(alias.lowercased())
            }
            var value: [String: AgentCLIJSONValue] = [
                "alias": .string(alias),
                "ref": .string(index < refs.count ? refs[index] : "acct-unknown"),
                "state": .string(account.state.rawValue),
                "usageStatus": .string(account.usageStatus.rawValue),
                "resetCreditStatus": .string(account.resetCreditStatus.rawValue),
                "windows": .array(account.windows.enumerated().map { windowIndex, window in
                    var windowValue: [String: AgentCLIJSONValue] = [
                        "label": .string(Self.safeWindowLabel(window.label, fallbackIndex: windowIndex + 1, privateValues: privateValues)),
                        "usedPercent": .integer(min(max(window.usedPercent, 0), 100)),
                        "remainingPercent": .integer(min(max(window.remainingPercent, 0), 100)),
                    ]
                    if let resetAt = window.resetAt { windowValue["resetAt"] = .string(Self.iso8601(resetAt)) }
                    return .object(windowValue)
                }),
            ]
            if let plan = account.plan, AgentSanitizer.safeAlias(plan, privateValues: []) != nil {
                value["plan"] = .string(plan)
            }
            if let count = account.availableResetCredits { value["availableResetCredits"] = .integer(max(0, count)) }
            if let expiry = account.earliestResetCreditExpiry { value["earliestResetCreditExpiry"] = .string(Self.iso8601(expiry)) }
            return .object(value)
        }
        return .object([
            "schemaVersion": .integer(report.schemaVersion),
            "fetchedAt": .string(Self.iso8601(report.fetchedAt)),
            "accounts": .array(accountValues),
        ])
    }

    private func warmupAll(_ command: AgentCLICommand) async -> AgentCLIResult {
        let accountRoster = await roster()
        let activeEntries = accountRoster.entries.filter { !$0.account.isArchived }
        let settings = await settingsStore.get()
        let runtimeURL = await runtimeURLCandidate(settings: settings)
        if !command.options.confirm && !command.options.dryRun {
            return confirmationRequired(command: command.canonicalName, action: "run warm-up")
        }
        guard Self.isUsableLoopback(runtimeURL) else {
            let reports = activeEntries.map { entry in
                AgentCLIJSONValue.object(["ref": .string(entry.reference), "status": .string("skippedProxyUnavailable")])
            }
            let data = AgentCLIJSONValue.object([
                "status": .string("proxyUnavailable"),
                "accounts": .array(reports),
                "counts": .object([
                    "total": .integer(activeEntries.count),
                    "warmed": .integer(0),
                    "skipped": .integer(activeEntries.count),
                    "failed": .integer(0),
                ]),
            ])
            return AgentCLIResult(envelope: .failure(command: command.canonicalName, code: "runtime_unavailable", message: "running loopback proxy is required for warm-up", data: data), exitCode: .unavailable)
        }
        if command.options.dryRun {
            let eligible = activeEntries.filter {
                AppEngine.quotaWarmupEligible($0.account, settings: settings)
                    && QuotaWarmupService.usageAllowsWarmup($0.account)
            }
            let eligibleRefs = Set(eligible.map(\.reference))
            let reports = activeEntries.map { entry in
                AgentCLIJSONValue.object([
                    "ref": .string(entry.reference),
                    "status": .string(eligibleRefs.contains(entry.reference) ? "wouldWarm" : "skipped"),
                ])
            }
            let data = AgentCLIJSONValue.object([
                "status": .string("dryRun"),
                "accounts": .array(reports),
                "counts": .object([
                    "total": .integer(activeEntries.count),
                    "eligible": .integer(eligible.count),
                ]),
            ])
            return AgentCLIResult(envelope: .success(command: command.canonicalName, data: data), exitCode: .ok)
        }

        let report = await HeadlessWarmup.run(
            proxyURL: runtimeURL,
            store: store,
            settings: settings,
            warmupService: warmupService
        )
        let statuses = report.accounts
        let reports = activeEntries.enumerated().map { index, entry in
            let status = index < statuses.count ? statuses[index].status.rawValue : "skipped"
            return AgentCLIJSONValue.object(["ref": .string(entry.reference), "status": .string(status)])
        }
        let data = AgentCLIJSONValue.object([
            "status": .string(report.status.rawValue),
            "accounts": .array(reports),
            "counts": .object([
                "total": .integer(report.counts.total),
                "warmed": .integer(report.counts.warmed),
                "skipped": .integer(report.counts.skipped),
                "failed": .integer(report.counts.failed),
            ]),
            "startedAt": .string(Self.iso8601(report.startedAt)),
            "finishedAt": .string(Self.iso8601(report.finishedAt)),
        ])
        if report.status == .failed {
            return AgentCLIResult(envelope: .failure(command: command.canonicalName, code: "warmup_failed", message: "one or more warm-up attempts failed", data: data), exitCode: .tempFailure)
        }
        return AgentCLIResult(envelope: .success(command: command.canonicalName, data: data), exitCode: .ok)
    }

    /// Warm exactly one resolved account.  The reset monitor uses this narrow
    /// command so a reset-triggered request cannot consume unrelated accounts
    /// from the roster.  The account reference is resolved against the same
    /// sanitized roster used by the other agent commands; the underlying
    /// warm-up service still enforces credentials, routing, usage and the
    /// shared interprocess lock.
    private func warmupAccount(target: String, command: AgentCLICommand) async -> AgentCLIResult {
        let accountRoster = await roster()
        guard let entry = accountRoster.resolve(target), !entry.account.isArchived else {
            return missingAccount(command: command.canonicalName)
        }
        if !command.options.confirm && !command.options.dryRun {
            return confirmationRequired(command: command.canonicalName, action: "run warm-up")
        }

        let settings = await settingsStore.get()
        let runtimeURL = await runtimeURLCandidate(settings: settings)
        let ref = entry.reference
        let unavailableData: AgentCLIJSONValue = .object([
            "status": .string("proxyUnavailable"),
            "ref": .string(ref),
            "accountStatus": .string("skippedProxyUnavailable"),
            "counts": .object([
                "total": .integer(1),
                "warmed": .integer(0),
                "skipped": .integer(1),
                "failed": .integer(0),
            ]),
        ])
        guard Self.isUsableLoopback(runtimeURL) else {
            return AgentCLIResult(
                envelope: .failure(
                    command: command.canonicalName,
                    code: "runtime_unavailable",
                    message: "running loopback proxy is required for warm-up",
                    data: unavailableData
                ),
                exitCode: .unavailable
            )
        }

        if command.options.dryRun {
            let eligible = AppEngine.quotaWarmupEligible(entry.account, settings: settings)
                && QuotaWarmupService.usageAllowsWarmup(entry.account)
            let data: AgentCLIJSONValue = .object([
                "status": .string("dryRun"),
                "ref": .string(ref),
                "accountStatus": .string(eligible ? "wouldWarm" : "skipped"),
                "counts": .object([
                    "total": .integer(1),
                    "eligible": .integer(eligible ? 1 : 0),
                ]),
            ])
            return AgentCLIResult(envelope: .success(command: command.canonicalName, data: data), exitCode: .ok)
        }

        let report = await HeadlessWarmup.run(
            proxyURL: runtimeURL,
            store: store,
            settings: settings,
            warmupService: warmupService,
            targetAliases: [entry.account.alias]
        )
        let accountStatus = report.accounts.first?.status.rawValue ?? "skipped"
        let data: AgentCLIJSONValue = .object([
            "status": .string(report.status.rawValue),
            "ref": .string(ref),
            "accountStatus": .string(accountStatus),
            "counts": .object([
                "total": .integer(report.counts.total),
                "warmed": .integer(report.counts.warmed),
                "skipped": .integer(report.counts.skipped),
                "failed": .integer(report.counts.failed),
            ]),
            "startedAt": .string(Self.iso8601(report.startedAt)),
            "finishedAt": .string(Self.iso8601(report.finishedAt)),
        ])
        if report.status == .failed || accountStatus == HeadlessWarmupAccountStatus.failed.rawValue {
            return AgentCLIResult(
                envelope: .failure(
                    command: command.canonicalName,
                    code: "warmup_failed",
                    message: "warm-up attempt failed",
                    data: data
                ),
                exitCode: .tempFailure
            )
        }
        return AgentCLIResult(envelope: .success(command: command.canonicalName, data: data), exitCode: .ok)
    }

    private func resetStatus(_ command: AgentCLICommand) async -> AgentCLIResult {
        await engine.refreshResetCreditStatuses()
        let snapshot = await engine.snapshot()
        let accountRoster = await roster()
        let statuses = accountRoster.entries.filter { !$0.account.isArchived }.map { entry -> AgentCLIJSONValue in
            let status = snapshot.resetCreditStatuses[entry.account.alias]
            return resetStatusView(reference: entry.reference, status: status)
        }
        let data = AgentCLIJSONValue.object(["accounts": .array(statuses), "count": .integer(statuses.count)])
        return AgentCLIResult(envelope: .success(command: command.canonicalName, data: data), exitCode: .ok)
    }

    private func resetStatusView(reference: String, status: AccountResetCreditStatus?) -> AgentCLIJSONValue {
        var value: [String: AgentCLIJSONValue] = ["ref": .string(reference)]
        switch status {
        case .loading: value["status"] = .string("loading")
        case .noCredit: value["status"] = .string("noCredit")
        case .available(let count, let expiry):
            value["status"] = .string("available")
            value["availableCount"] = .integer(max(0, count))
            if let expiry { value["earliestExpiry"] = .string(Self.iso8601(expiry)) }
        case .networkFailure: value["status"] = .string("networkFailure")
        case .unavailable, nil: value["status"] = .string("unavailable")
        }
        return .object(value)
    }

    private func resetUse(target: String, command: AgentCLICommand) async -> AgentCLIResult {
        let accountRoster = await roster()
        guard let entry = accountRoster.resolve(target), !entry.account.isArchived else { return missingAccount(command: command.canonicalName) }
        if !command.options.confirm && !command.options.dryRun {
            return confirmationRequired(command: command.canonicalName, action: "use a reset credit")
        }
        if command.options.dryRun {
            return AgentCLIResult(envelope: .success(command: command.canonicalName, data: .object(["ref": .string(entry.reference), "wouldUse": .bool(true)])), exitCode: .ok)
        }
        let outcome = await engine.resetQuota(alias: entry.account.alias, trigger: .manual)
        switch outcome {
        case .reset(let windowsReset):
            return AgentCLIResult(envelope: .success(command: command.canonicalName, data: .object(["ref": .string(entry.reference), "outcome": .string("reset"), "windowsReset": .integer(max(0, windowsReset))])), exitCode: .ok)
        case .nothingToReset:
            return resetOutcome(reference: entry.reference, outcome: "nothingToReset")
        case .noCredit:
            return resetOutcome(reference: entry.reference, outcome: "noCredit")
        case .alreadyRedeemed:
            return resetOutcome(reference: entry.reference, outcome: "alreadyRedeemed")
        case .accountUnavailable:
            return missingAccount(command: command.canonicalName)
        case .authorizationFailed:
            return AgentCLIResult(envelope: .failure(command: command.canonicalName, code: "authorization_failed", message: "reset service authorization failed"), exitCode: .tempFailure)
        case .networkFailure, .ambiguousFailure:
            return AgentCLIResult(envelope: .failure(command: command.canonicalName, code: "reset_service_unavailable", message: "reset service could not be reached safely"), exitCode: .tempFailure)
        case .cancelled:
            return cancelled(command: command.canonicalName)
        case .automaticDisabled, .protectedAccount, .failed:
            return AgentCLIResult(envelope: .failure(command: command.canonicalName, code: "reset_failed", message: "reset could not be completed"), exitCode: .software)
        }
    }

    private func resetOutcome(reference: String, outcome: String) -> AgentCLIResult {
        AgentCLIResult(envelope: .success(command: "agent reset use", data: .object(["ref": .string(reference), "outcome": .string(outcome)])), exitCode: .ok)
    }

    private func routingGet(_ command: AgentCLICommand) async -> AgentCLIResult {
        let snapshot = await engine.snapshot()
        let settings = await settingsStore.get()
        let runtimeURL = await runtimeURLCandidate(settings: settings)
        let data = AgentCLIJSONValue.object([
            "state": Self.routingValue(snapshot.routingState),
            "configured": .bool(settings.routeCodexAutomatically),
            "proxyAvailable": .bool(Self.isUsableLoopback(runtimeURL)),
        ])
        return AgentCLIResult(envelope: .success(command: command.canonicalName, data: data), exitCode: .ok)
    }

    private func routingSet(enabled: Bool, command: AgentCLICommand) async -> AgentCLIResult {
        if command.options.dryRun {
            return AgentCLIResult(envelope: .success(command: command.canonicalName, data: .object(["wouldEnable": .bool(enabled)])), exitCode: .ok)
        }
        let settings = await settingsStore.get()
        let runtimeURL = await runtimeURLCandidate(settings: settings)
        if enabled && !Self.isUsableLoopback(runtimeURL) {
            return AgentCLIResult(envelope: .failure(command: command.canonicalName, code: "runtime_unavailable", message: "running loopback proxy is required for routing"), exitCode: .unavailable)
        }
        do {
            try await engine.setAutomaticRouting(enabled, proxyURL: runtimeURL)
        } catch is CancellationError {
            return cancelled(command: command.canonicalName)
        } catch is AppEngineError {
            return AgentCLIResult(envelope: .failure(command: command.canonicalName, code: "runtime_unavailable", message: "running loopback proxy is required for routing"), exitCode: .unavailable)
        } catch is CodexConfigManagerError {
            return AgentCLIResult(envelope: .failure(command: command.canonicalName, code: "routing_configuration_error", message: "routing configuration could not be changed safely"), exitCode: .tempFailure)
        } catch {
            return AgentCLIResult(envelope: .failure(command: command.canonicalName, code: "routing_configuration_error", message: "routing configuration could not be changed safely"), exitCode: .software)
        }
        return await routingGet(command)
    }

    private func routingRepair(_ command: AgentCLICommand) async -> AgentCLIResult {
        if command.options.dryRun {
            return AgentCLIResult(envelope: .success(command: command.canonicalName, data: .object(["wouldRepair": .bool(true)])), exitCode: .ok)
        }
        let settings = await settingsStore.get()
        let runtimeURL = await runtimeURLCandidate(settings: settings)
        guard Self.isUsableLoopback(runtimeURL) else {
            return AgentCLIResult(envelope: .failure(command: command.canonicalName, code: "runtime_unavailable", message: "running loopback proxy is required for routing repair"), exitCode: .unavailable)
        }
        do {
            try await engine.repairAutomaticRouting(proxyURL: runtimeURL)
        } catch is CancellationError {
            return cancelled(command: command.canonicalName)
        } catch is AppEngineError {
            return AgentCLIResult(envelope: .failure(command: command.canonicalName, code: "runtime_unavailable", message: "running loopback proxy is required for routing repair"), exitCode: .unavailable)
        } catch is CodexConfigManagerError {
            return AgentCLIResult(envelope: .failure(command: command.canonicalName, code: "routing_configuration_error", message: "routing configuration could not be repaired safely"), exitCode: .tempFailure)
        } catch {
            return AgentCLIResult(envelope: .failure(command: command.canonicalName, code: "routing_configuration_error", message: "routing configuration could not be repaired safely"), exitCode: .software)
        }
        return await routingGet(command)
    }

    private enum SettingKind: Sendable {
        case bool
        case integer(range: ClosedRange<Int>)
        case strategy
        case exhaustionPolicy
    }

    private static let settingKinds: [String: SettingKind] = [
        "rotationStrategy": .strategy,
        "primaryThresholdPercent": .integer(range: 0...100),
        "secondaryThresholdPercent": .integer(range: 0...100),
        "usagePollSeconds": .integer(range: 1...86_400),
        "defaultCooldownSeconds": .integer(range: 0...604_800),
        "roundRobinTurnGapSeconds": .integer(range: 0...3_600),
        "notifyOnRotate": .bool,
        "notifyOnExhausted": .bool,
        "notifyOnWindowReset": .bool,
        "launchAtLogin": .bool,
        "automaticallyWarmAccounts": .bool,
        "automaticallyResetExhaustedAccounts": .bool,
        "interactiveExhaustionPolicy": .exhaustionPolicy,
        "notifyOnNeedsLogin": .bool,
        "smartSwitchEnabled": .bool,
        "metadataTelemetryEnabled": .bool,
    ]

    /// Registration with the host login service is owned by the app process;
    /// changing this persisted preference takes effect after the app reloads.
    private static let settingRestartRequired: Set<String> = [
        // Launch registration and the telemetry actor are initialized by the
        // host app at startup; a standalone agent process cannot safely poke
        // those live resources.
        "launchAtLogin",
        "metadataTelemetryEnabled",
    ]

    private func settingsGet(key: String?, command: AgentCLICommand) async -> AgentCLIResult {
        let settings = await settingsStore.get()
        if let key {
            guard Self.settingKinds[key] != nil else { return unknownSetting(command: command.canonicalName) }
            let value = Self.settingValue(settings, key: key)
            return AgentCLIResult(envelope: .success(command: command.canonicalName, data: .object(["key": .string(key), "value": value])), exitCode: .ok)
        }
        var values: [String: AgentCLIJSONValue] = [:]
        for key in Self.settingKinds.keys.sorted() { values[key] = Self.settingValue(settings, key: key) }
        return AgentCLIResult(envelope: .success(command: command.canonicalName, data: .object(["settings": .object(values)])), exitCode: .ok)
    }

    private func settingsSet(key: String, rawValue: String, command: AgentCLICommand) async -> AgentCLIResult {
        guard let kind = Self.settingKinds[key] else { return unknownSetting(command: command.canonicalName) }
        guard let parsed = Self.parseSetting(rawValue, kind: kind) else {
            return AgentCLIResult(envelope: .failure(command: command.canonicalName, code: "invalid_setting_value", message: "setting value has the wrong type or range"), exitCode: .data)
        }
        let previous = await settingsStore.get()
        if command.options.dryRun {
            return AgentCLIResult(envelope: .success(command: command.canonicalName, data: .object(["key": .string(key), "value": parsed, "dryRun": .bool(true)])), exitCode: .ok)
        }
        let updated: Settings
        do {
            updated = try await settingsStore.updatePersisting { settings in
                Self.applySetting(&settings, key: key, value: parsed)
            }
        } catch {
            return AgentCLIResult(
                envelope: .failure(command: command.canonicalName, code: "settings_write_failed", message: "settings could not be persisted safely"),
                exitCode: .permission
            )
        }
        await engine.settingsDidChange(from: previous, to: updated)
        let restartRequired = Self.settingRestartRequired.contains(key)
        return AgentCLIResult(
            envelope: .success(
                command: command.canonicalName,
                data: .object([
                    "key": .string(key),
                    "value": Self.settingValue(updated, key: key),
                    "persisted": .bool(true),
                    "restartRequired": .bool(restartRequired),
                ]),
                warnings: restartRequired ? ["restart_required_for_live_app"] : nil
            ),
            exitCode: .ok
        )
    }

    private func unknownSetting(command: String) -> AgentCLIResult {
        AgentCLIResult(envelope: .failure(command: command, code: "setting_not_allowlisted", message: "setting is not allowlisted for agent control"), exitCode: .data)
    }

    private static func parseSetting(_ raw: String, kind: SettingKind) -> AgentCLIJSONValue? {
        switch kind {
        case .bool:
            switch raw.lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: return nil
            }
        case .integer(let range):
            guard let integer = Int(raw), range.contains(integer) else { return nil }
            return .integer(integer)
        case .strategy:
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return RotationStrategy.allCases.first { $0.rawValue.lowercased() == normalized }
                .map { .string($0.rawValue) }
        case .exhaustionPolicy:
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return QuotaExhaustionPolicy.allCases.first { $0.rawValue.lowercased() == normalized }
                .map { .string($0.rawValue) }
        }
    }

    private static func settingValue(_ settings: Settings, key: String) -> AgentCLIJSONValue {
        switch key {
        case "rotationStrategy": return .string(settings.rotationStrategy.rawValue)
        case "primaryThresholdPercent": return .integer(settings.primaryThresholdPercent)
        case "secondaryThresholdPercent": return .integer(settings.secondaryThresholdPercent)
        case "usagePollSeconds": return .integer(settings.usagePollSeconds)
        case "defaultCooldownSeconds": return .integer(settings.defaultCooldownSeconds)
        case "roundRobinTurnGapSeconds": return .integer(settings.roundRobinTurnGapSeconds)
        case "notifyOnRotate": return .bool(settings.notifyOnRotate)
        case "notifyOnExhausted": return .bool(settings.notifyOnExhausted)
        case "notifyOnWindowReset": return .bool(settings.notifyOnWindowReset)
        case "launchAtLogin": return .bool(settings.launchAtLogin)
        case "automaticallyWarmAccounts": return .bool(settings.automaticallyWarmAccounts)
        case "automaticallyResetExhaustedAccounts": return .bool(settings.automaticallyResetExhaustedAccounts)
        case "interactiveExhaustionPolicy": return .string(settings.interactiveExhaustionPolicy.rawValue)
        case "notifyOnNeedsLogin": return .bool(settings.notifyOnNeedsLogin)
        case "smartSwitchEnabled": return .bool(settings.smartSwitchEnabled)
        case "metadataTelemetryEnabled": return .bool(settings.metadataTelemetryEnabled)
        default: return .null
        }
    }

    private static func applySetting(_ settings: inout Settings, key: String, value: AgentCLIJSONValue) {
        switch key {
        case "rotationStrategy":
            if case .string(let raw) = value, let strategy = RotationStrategy(rawValue: raw) { settings.rotationStrategy = strategy }
        case "primaryThresholdPercent": if case .integer(let value) = value { settings.primaryThresholdPercent = value }
        case "secondaryThresholdPercent": if case .integer(let value) = value { settings.secondaryThresholdPercent = value }
        case "usagePollSeconds": if case .integer(let value) = value { settings.usagePollSeconds = value }
        case "defaultCooldownSeconds": if case .integer(let value) = value { settings.defaultCooldownSeconds = value }
        case "roundRobinTurnGapSeconds": if case .integer(let value) = value { settings.roundRobinTurnGapSeconds = value }
        case "notifyOnRotate": if case .bool(let value) = value { settings.notifyOnRotate = value }
        case "notifyOnExhausted": if case .bool(let value) = value { settings.notifyOnExhausted = value }
        case "notifyOnWindowReset": if case .bool(let value) = value { settings.notifyOnWindowReset = value }
        case "launchAtLogin": if case .bool(let value) = value { settings.launchAtLogin = value }
        case "automaticallyWarmAccounts": if case .bool(let value) = value { settings.automaticallyWarmAccounts = value }
        case "automaticallyResetExhaustedAccounts": if case .bool(let value) = value { settings.automaticallyResetExhaustedAccounts = value }
        case "interactiveExhaustionPolicy":
            if case .string(let raw) = value, let policy = QuotaExhaustionPolicy(rawValue: raw) { settings.interactiveExhaustionPolicy = policy }
        case "notifyOnNeedsLogin": if case .bool(let value) = value { settings.notifyOnNeedsLogin = value }
        case "smartSwitchEnabled": if case .bool(let value) = value { settings.smartSwitchEnabled = value }
        case "metadataTelemetryEnabled": if case .bool(let value) = value { settings.metadataTelemetryEnabled = value }
        default: break
        }
    }
}
