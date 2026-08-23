import Foundation
import XCTest
@testable import SwapKit

final class CodexSubagentPolicyManagerTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let codexHome: URL
        let agents: URL
        let overlay: URL

        init(roleFiles: [String: String], overlay: String) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("codexswap-policy-\(UUID().uuidString)", isDirectory: true)
            codexHome = root.appendingPathComponent(".codex", isDirectory: true)
            agents = codexHome.appendingPathComponent("agents", isDirectory: true)
            self.overlay = codexHome.appendingPathComponent("model-catalogs/luna-v2.json")
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: self.overlay.deletingLastPathComponent(), withIntermediateDirectories: true)
            for (roleID, content) in roleFiles {
                try Data(content.utf8).write(to: agents.appendingPathComponent("\(roleID).toml"))
            }
            try Data(overlay.utf8).write(to: self.overlay)
        }

        func write(_ content: String, to url: URL) throws {
            try Data(content.utf8).write(to: url)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private final class WriteRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var targets: [CodexSubagentPolicyTarget] = []
        private(set) var stages: [CodexSubagentPolicyMutationStage] = []

        func record(_ stage: CodexSubagentPolicyMutationStage) {
            lock.lock()
            stages.append(stage)
            if case .beforeWrite(let target) = stage { targets.append(target) }
            lock.unlock()
        }
    }

    private final class MetadataFailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var enabled = false

        func enable() {
            lock.lock()
            enabled = true
            lock.unlock()
        }

        func shouldFail(_ url: URL) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return enabled && url.pathExtension == "toml"
        }
    }

    private final class ConcurrencyProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private(set) var maxActive = 0

        func enter() {
            lock.lock()
            active += 1
            maxActive = max(maxActive, active)
            lock.unlock()
            usleep(20_000)
        }

        func leave() {
            lock.lock()
            active -= 1
            lock.unlock()
        }
    }

    private final class AtomicFailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var shouldFail = false

        func enable() {
            lock.lock()
            shouldFail = true
            lock.unlock()
        }

        func isEnabled() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return shouldFail
        }
    }

    func testReplacesOnlyTopLevelManagedValuesAndPreservesCommentsInstructionsAndTables() throws {
        let original = #"""
        # role-owned heading
        model = "gpt-old" # keep this comment
        custom_key = { "model" = "custom" }
        model_reasoning_effort = "low"
        developer_instructions = """
        fake = true
        model = "fake-inside-instructions"
        """

        [permissions] # preserve table header comment
        model = "fake-inside-table"
        # trailing table comment
        """#
        let fixture = try Fixture(
            roleFiles: ["worker": original],
            overlay: alphaOverlay(efforts: ["max"])
        )
        defer { fixture.cleanup() }
        let manager = makeManager(fixture)

        try manager.apply(
            policy: policy(role: "worker", model: "gpt-5.6-luna", effort: .max),
            catalog: [gptDescriptor],
            installedRoleIDs: ["worker"]
        )

        let rewritten = try String(contentsOf: fixture.agents.appendingPathComponent("worker.toml"), encoding: .utf8)
        XCTAssertTrue(rewritten.contains("model = \"gpt-5.6-luna\" # keep this comment"))
        XCTAssertTrue(rewritten.contains("model_reasoning_effort = \"max\""))
        XCTAssertTrue(rewritten.contains("custom_key = { \"model\" = \"custom\" }"))
        XCTAssertTrue(rewritten.contains("model = \"fake-inside-instructions\""))
        XCTAssertTrue(rewritten.contains("model = \"fake-inside-table\""))
        XCTAssertTrue(rewritten.contains("[permissions] # preserve table header comment"))
        XCTAssertEqual(rewritten.filter { $0 == "\n" }.count, original.filter { $0 == "\n" }.count)
    }

    func testInsertsMissingManagedKeysBeforeDeveloperInstructionsAndFirstTable() throws {
        let original = #"""
        # preserve heading
        custom = true
        developer_instructions = """
        Keep these instructions.
        """

        [permissions]
        read = true
        """#
        let fixture = try Fixture(
            roleFiles: ["worker": original],
            overlay: alphaOverlay(efforts: ["max"])
        )
        defer { fixture.cleanup() }

        try makeManager(fixture).apply(
            policy: policy(role: "worker", model: "gpt-5.6-luna", effort: .max),
            catalog: [gptDescriptor],
            installedRoleIDs: ["worker"]
        )
        let rewritten = try String(contentsOf: fixture.agents.appendingPathComponent("worker.toml"), encoding: .utf8)
        let modelOffset = try XCTUnwrap(rewritten.range(of: "model = \"gpt-5.6-luna\""))
        let instructionsOffset = try XCTUnwrap(rewritten.range(of: "developer_instructions"))
        XCTAssertLessThan(modelOffset.lowerBound, instructionsOffset.lowerBound)
        XCTAssertTrue(rewritten.contains("model_reasoning_effort = \"max\""))
        XCTAssertTrue(rewritten.contains("Keep these instructions."))
        XCTAssertTrue(rewritten.contains("[permissions]"))
    }

    func testInsertionUsesOriginalOffsetAfterLongModelReplacement() throws {
        let original = #"""
        model = "short"
        custom = true
        developer_instructions = """
        Keep these instructions.
        """

        [permissions]
        read = true
        """#
        let fixture = try Fixture(
            roleFiles: ["worker": original],
            overlay: alphaOverlay(efforts: ["max"])
        )
        defer { fixture.cleanup() }
        let longModel = "gpt-5.6-luna-with-a-deliberately-long-future-model-suffix"
        try makeManager(fixture).apply(
            policy: policy(role: "worker", model: longModel, effort: .max),
            catalog: [
                CodexModelDescriptor(
                    modelID: longModel,
                    displayName: "Future Luna",
                    supportedReasoningEfforts: [.max],
                    providerFamily: .openAI
                )
            ],
            installedRoleIDs: ["worker"]
        )

        let rewritten = try String(contentsOf: fixture.agents.appendingPathComponent("worker.toml"), encoding: .utf8)
        let expected = #"""
        model = "gpt-5.6-luna-with-a-deliberately-long-future-model-suffix"
        custom = true
        model_reasoning_effort = "max"
        developer_instructions = """
        Keep these instructions.
        """

        [permissions]
        read = true
        """#
        XCTAssertEqual(rewritten, expected)
    }

    func testCRLFTableHeaderPreservesNestedManagedKeysAndInsertsBeforeTable() throws {
        let original = "model = \"old\"\r\ncustom = true\r\n[permissions]\r\nmodel = \"nested\"\r\nmodel_reasoning_effort = \"nested\"\r\n"
        let fixture = try Fixture(
            roleFiles: ["worker": original],
            overlay: alphaOverlay(efforts: ["max"])
        )
        defer { fixture.cleanup() }

        try makeManager(fixture).apply(
            policy: policy(role: "worker"),
            catalog: [gptDescriptor],
            installedRoleIDs: ["worker"]
        )

        let rewritten = try String(contentsOf: fixture.agents.appendingPathComponent("worker.toml"), encoding: .utf8)
        let expected = "model = \"gpt-5.6-luna\"\r\ncustom = true\r\nmodel_reasoning_effort = \"max\"\r\n[permissions]\r\nmodel = \"nested\"\r\nmodel_reasoning_effort = \"nested\"\r\n"
        XCTAssertEqual(rewritten, expected)
        XCTAssertEqual(rewritten.components(separatedBy: "\r\n").count - 1, 6)
    }

    func testExplicitRoleFileBindingUsesLogicalNameNotFilename() throws {
        let roleURLName = "luna-clerk"
        let roleID = "luna_clerk"
        let original = "name = \"\(roleID)\"\nmodel = \"gpt-old\"\nmodel_reasoning_effort = \"low\"\n"
        let fixture = try Fixture(roleFiles: [roleURLName: original], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }
        let binding = CodexSubagentRoleFile(
            roleID: roleID,
            fileURL: fixture.agents.appendingPathComponent("\(roleURLName).toml")
        )

        try makeManager(fixture).apply(
            policy: policy(role: roleID),
            catalog: [gptDescriptor],
            roleFiles: [binding]
        )

        XCTAssertEqual(
            try String(contentsOf: binding.fileURL, encoding: .utf8),
            "name = \"\(roleID)\"\nmodel = \"gpt-5.6-luna\"\nmodel_reasoning_effort = \"max\"\n"
        )
    }

    func testMacOSVarPrivateVarAliasIsAcceptedForDirectRoleBinding() throws {
        let relative = "codexswap-policy-alias-\(UUID().uuidString)"
        let realRoot = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
            .appendingPathComponent(relative, isDirectory: true)
        let realHome = realRoot.appendingPathComponent(".codex", isDirectory: true)
        let realAgents = realHome.appendingPathComponent("agents", isDirectory: true)
        let realOverlayDirectory = realHome.appendingPathComponent("model-catalogs", isDirectory: true)
        let realOverlay = realOverlayDirectory.appendingPathComponent("luna-v2.json")
        try FileManager.default.createDirectory(at: realAgents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realOverlayDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: realRoot) }

        let roleURL = realAgents.appendingPathComponent("luna-clerk.toml")
        try Data("name = \"luna_clerk\"\nmodel = \"old\"\nmodel_reasoning_effort = \"low\"\n".utf8).write(to: roleURL)
        try Data(alphaOverlay(efforts: ["max"]).utf8).write(to: realOverlay)

        let aliasRoot = URL(fileURLWithPath: realRoot.path.replacingOccurrences(of: "/private/var", with: "/var"), isDirectory: true)
        let aliasHome = aliasRoot.appendingPathComponent(".codex", isDirectory: true)
        let aliasRole = aliasHome.appendingPathComponent("agents/luna-clerk.toml")
        let aliasOverlay = aliasHome.appendingPathComponent("model-catalogs/luna-v2.json")
        let binding = CodexSubagentRoleFile(roleID: "luna_clerk", fileURL: aliasRole)
        try CodexSubagentPolicyManager(codexHome: aliasHome, catalogOverlayURL: aliasOverlay).apply(
            policy: policy(role: "luna_clerk"),
            catalog: [gptDescriptor],
            roleFiles: [binding]
        )

        XCTAssertTrue(try String(contentsOf: roleURL, encoding: .utf8).contains("gpt-5.6-luna"))
    }

    func testUnterminatedMultilineAndMalformedTableHeadersFailBeforeWrites() throws {
        let originals = [
            "model = \"old\"\nmodel_reasoning_effort = \"low\"\ndeveloper_instructions = \"\"\"\nmodel = \"nested\"\n",
            "model = \"old\"\nmodel_reasoning_effort = \"low\"\n[permissions] trailing\nmodel = \"nested\"\n",
            "model = \"old\"\nmodel_reasoning_effort = \"low\"\n[permissions\nmodel = \"nested\"\n",
        ]
        for original in originals {
            let fixture = try Fixture(roleFiles: ["worker": original], overlay: alphaOverlay(efforts: ["max"]))
            defer { fixture.cleanup() }
            let recorder = WriteRecorder()
            let manager = makeManager(fixture) { recorder.record($0) }
            XCTAssertThrowsError(try manager.apply(
                policy: policy(role: "worker"),
                catalog: [gptDescriptor],
                installedRoleIDs: ["worker"]
            )) { error in
                guard case .malformedRole("worker") = error as? CodexSubagentPolicyManagerError else {
                    return XCTFail("Expected malformed role, got \(error)")
                }
            }
            XCTAssertTrue(recorder.targets.isEmpty)
            XCTAssertEqual(try Data(contentsOf: fixture.agents.appendingPathComponent("worker.toml")), Data(original.utf8))
        }

        // A # inside a quoted table key is part of the key, not a comment.
        // The valid table must be recognized so its nested managed-looking
        // assignment is preserved byte-for-byte rather than treated as a
        // duplicate top-level key.
        let validQuotedHeader = "model = \"old\"\nmodel_reasoning_effort = \"low\"\n[permissions.\"nested#key\"] # comment ]\nmodel = \"nested\"\n"
        let fixture = try Fixture(roleFiles: ["worker": validQuotedHeader], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }
        try makeManager(fixture).apply(
            policy: policy(role: "worker"),
            catalog: [gptDescriptor],
            installedRoleIDs: ["worker"]
        )
        let rewritten = try Data(contentsOf: fixture.agents.appendingPathComponent("worker.toml"))
        let expected = "model = \"gpt-5.6-luna\"\nmodel_reasoning_effort = \"max\"\n[permissions.\"nested#key\"] # comment ]\nmodel = \"nested\"\n"
        XCTAssertEqual(rewritten, Data(expected.utf8))
    }

    func testAlphaSyntheticMarkerAndDisableStateFailClosedWithoutWrites() throws {
        let invalidMarker = #"{"models":[{"slug":"x-preview-f-free","supported_reasoning_levels":[{"effort":"max","codexswap_synthetic_ultra":false}]}]}"#
        let emptyAfterDisable = #"{"models":[{"slug":"x-preview-f-free","supported_reasoning_levels":[{"effort":"ultra","codexswap_synthetic_ultra":true}]}]}"#
        for overlay in [invalidMarker, emptyAfterDisable] {
            let fixture = try Fixture(roleFiles: ["worker": validRole], overlay: overlay)
            defer { fixture.cleanup() }
            let recorder = WriteRecorder()
            XCTAssertThrowsError(try makeManager(fixture) { recorder.record($0) }.apply(
                policy: policy(role: "worker", alphaUltra: false),
                catalog: [gptDescriptor, alphaDescriptor],
                installedRoleIDs: ["worker"]
            ))
            XCTAssertTrue(recorder.targets.isEmpty)
            XCTAssertEqual(try Data(contentsOf: fixture.overlay), Data(overlay.utf8))
        }
    }

    func testAtomicReplaceFailureOnOverlayRollsBackPriorRoleWrite() throws {
        let fixture = try Fixture(roleFiles: ["worker": validRole], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }
        let live = CodexSubagentPolicyFileSystem.live
        let failure = AtomicFailureBox()
        let manager = CodexSubagentPolicyManager(
            codexHome: fixture.codexHome,
            catalogOverlayURL: fixture.overlay,
            fileSystem: CodexSubagentPolicyFileSystem(
                readData: live.readData,
                metadata: live.metadata,
                atomicReplace: { data, url, permissions in
                    if url == fixture.overlay, !failure.isEnabled() {
                        failure.enable()
                        throw TestFailure.injected
                    }
                    try live.atomicReplace(data, url, permissions)
                }
            )
        )

        XCTAssertThrowsError(try manager.apply(
            policy: policy(role: "worker", alphaUltra: true),
            catalog: [gptDescriptor, alphaDescriptor],
            installedRoleIDs: ["worker"]
        )) { error in
            guard case .writeFailed(.overlay) = error as? CodexSubagentPolicyManagerError else {
                return XCTFail("Expected overlay atomic replacement failure, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.agents.appendingPathComponent("worker.toml")), Data(validRole.utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.overlay), Data(alphaOverlay(efforts: ["max"]).utf8))
    }

    func testOverlayPostWriteFailureRollsBackOverlayAndPriorRoles() throws {
        let fixture = try Fixture(roleFiles: ["worker": validRole], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }
        let manager = makeManager(fixture) { stage in
            if case .afterWrite(.overlay) = stage { throw TestFailure.injected }
        }

        XCTAssertThrowsError(try manager.apply(
            policy: policy(role: "worker", alphaUltra: true),
            catalog: [gptDescriptor, alphaDescriptor],
            installedRoleIDs: ["worker"]
        ))
        XCTAssertEqual(try Data(contentsOf: fixture.agents.appendingPathComponent("worker.toml")), Data(validRole.utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.overlay), Data(alphaOverlay(efforts: ["max"]).utf8))
    }

    func testRoleFileBindingValidationRejectsMismatchesDuplicatesAndUnsafePathsBeforeWrites() throws {
        struct Case {
            let name: String
            let makeBindings: (Fixture) throws -> [CodexSubagentRoleFile]
            let roleFiles: [String: String]
        }
        let cases: [Case] = [
            Case(
                name: "mismatched name",
                makeBindings: { fixture in
                    [CodexSubagentRoleFile(
                        roleID: "worker",
                        fileURL: fixture.agents.appendingPathComponent("worker.toml")
                    )]
                },
                roleFiles: ["worker": "name = \"other\"\nmodel = \"old\"\nmodel_reasoning_effort = \"low\"\n"]
            ),
            Case(
                name: "duplicate logical binding",
                makeBindings: { fixture in
                    let url = fixture.agents.appendingPathComponent("worker.toml")
                    return [
                        CodexSubagentRoleFile(roleID: "worker", fileURL: url),
                        CodexSubagentRoleFile(roleID: "worker", fileURL: url),
                    ]
                },
                roleFiles: ["worker": "name = \"worker\"\nmodel = \"old\"\nmodel_reasoning_effort = \"low\"\n"]
            ),
            Case(
                name: "duplicate URL",
                makeBindings: { fixture in
                    let url = fixture.agents.appendingPathComponent("worker.toml")
                    return [
                        CodexSubagentRoleFile(roleID: "worker", fileURL: url),
                        CodexSubagentRoleFile(roleID: "other", fileURL: url),
                    ]
                },
                roleFiles: ["worker": "name = \"worker\"\nmodel = \"old\"\nmodel_reasoning_effort = \"low\"\n"]
            ),
            Case(
                name: "wrong extension",
                makeBindings: { fixture in
                    let url = fixture.agents.appendingPathComponent("worker.bak")
                    try Data("name = \"worker\"\n".utf8).write(to: url)
                    return [CodexSubagentRoleFile(roleID: "worker", fileURL: url)]
                },
                roleFiles: ["worker": "name = \"worker\"\nmodel = \"old\"\nmodel_reasoning_effort = \"low\"\n"]
            ),
            Case(
                name: "nested URL",
                makeBindings: { fixture in
                    let nested = fixture.agents.appendingPathComponent("nested", isDirectory: true)
                    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
                    let url = nested.appendingPathComponent("worker.toml")
                    try Data("name = \"worker\"\n".utf8).write(to: url)
                    return [CodexSubagentRoleFile(roleID: "worker", fileURL: url)]
                },
                roleFiles: ["worker": "name = \"worker\"\nmodel = \"old\"\nmodel_reasoning_effort = \"low\"\n"]
            ),
            Case(
                name: "outside URL",
                makeBindings: { fixture in
                    let outside = fixture.root.appendingPathComponent("worker.toml")
                    try Data("name = \"worker\"\n".utf8).write(to: outside)
                    return [CodexSubagentRoleFile(roleID: "worker", fileURL: outside)]
                },
                roleFiles: ["worker": "name = \"worker\"\nmodel = \"old\"\nmodel_reasoning_effort = \"low\"\n"]
            ),
        ]

        for testCase in cases {
            let fixture = try Fixture(roleFiles: testCase.roleFiles, overlay: alphaOverlay(efforts: ["max"]))
            let recorder = WriteRecorder()
            defer { fixture.cleanup() }
            let bindings = try testCase.makeBindings(fixture)
            let manager = makeManager(fixture) { recorder.record($0) }
            XCTAssertThrowsError(try manager.apply(
                policy: policy(role: "worker"),
                catalog: [gptDescriptor],
                roleFiles: bindings
            ), "Expected (testCase.name) to fail")
            XCTAssertTrue(recorder.targets.isEmpty, "(testCase.name) performed a write")
        }
    }

    func testRoleFileBindingRejectsSymlinkAndAmbiguousTopLevelNameBeforeWrites() throws {
        let fixture = try Fixture(
            roleFiles: ["worker": "name = \"worker\"\nname = \"worker\"\nmodel = \"old\"\nmodel_reasoning_effort = \"low\"\n"],
            overlay: alphaOverlay(efforts: ["max"])
        )
        defer { fixture.cleanup() }
        let recorder = WriteRecorder()
        let manager = makeManager(fixture) { recorder.record($0) }
        let binding = CodexSubagentRoleFile(
            roleID: "worker",
            fileURL: fixture.agents.appendingPathComponent("worker.toml")
        )

        XCTAssertThrowsError(try manager.apply(
            policy: policy(role: "worker"),
            catalog: [gptDescriptor],
            roleFiles: [binding]
        ))
        XCTAssertTrue(recorder.targets.isEmpty)

        let outside = fixture.root.appendingPathComponent("outside.toml")
        try Data("name = \"worker\"\nmodel = \"old\"\nmodel_reasoning_effort = \"low\"\n".utf8).write(to: outside)
        try FileManager.default.removeItem(at: binding.fileURL)
        try FileManager.default.createSymbolicLink(at: binding.fileURL, withDestinationURL: outside)
        XCTAssertThrowsError(try manager.apply(
            policy: policy(role: "worker"),
            catalog: [gptDescriptor],
            roleFiles: [CodexSubagentRoleFile(roleID: "worker", fileURL: binding.fileURL)]
        ))
        XCTAssertTrue(recorder.targets.isEmpty)
    }

    func testExplicitRoleBindingRejectsMalformedTopLevelNameAndSpecialFileMetadata() throws {
        let malformedFixture = try Fixture(
            roleFiles: ["worker": "name = \"worker\"\nname = \"worker\"\nmodel = \"old\"\nmodel_reasoning_effort = \"low\"\n"],
            overlay: alphaOverlay(efforts: ["max"])
        )
        defer { malformedFixture.cleanup() }
        let recorder = WriteRecorder()
        let manager = makeManager(malformedFixture) { recorder.record($0) }
        let binding = CodexSubagentRoleFile(
            roleID: "worker",
            fileURL: malformedFixture.agents.appendingPathComponent("worker.toml")
        )
        XCTAssertThrowsError(try manager.apply(
            policy: policy(role: "worker"),
            catalog: [gptDescriptor],
            roleFiles: [binding]
        ))
        XCTAssertTrue(recorder.targets.isEmpty)

        let specialFixture = try Fixture(roleFiles: ["worker": validRole], overlay: alphaOverlay(efforts: ["max"]))
        defer { specialFixture.cleanup() }
        let specialRecorder = WriteRecorder()
        let regularMetadata = CodexSubagentPolicyFileSystem.live.metadata
        let specialURL = specialFixture.agents.appendingPathComponent("worker.toml")
        let specialFS = CodexSubagentPolicyFileSystem(
            readData: CodexSubagentPolicyFileSystem.live.readData,
            metadata: { url in
                if url == specialURL {
                    return CodexSubagentPolicyFileMetadata(
                        isDirectory: false,
                        isSymbolicLink: false,
                        isRegularFile: false
                    )
                }
                return try regularMetadata(url)
            },
            atomicReplace: CodexSubagentPolicyFileSystem.live.atomicReplace
        )
        let specialManager = CodexSubagentPolicyManager(
            codexHome: specialFixture.codexHome,
            catalogOverlayURL: specialFixture.overlay,
            fileSystem: specialFS,
            mutationHook: { specialRecorder.record($0) }
        )
        XCTAssertThrowsError(try specialManager.apply(
            policy: policy(role: "worker"),
            catalog: [gptDescriptor],
            installedRoleIDs: ["worker"]
        ))
        XCTAssertTrue(specialRecorder.targets.isEmpty)
    }

    func testOptionalBOMIsPreservedWhileManagedKeysAreReplaced() throws {
        let original = "\u{FEFF}model = \"old\"\nmodel_reasoning_effort = \"low\"\n"
        let fixture = try Fixture(roleFiles: ["worker": original], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }

        try makeManager(fixture).apply(
            policy: policy(role: "worker"),
            catalog: [gptDescriptor],
            installedRoleIDs: ["worker"]
        )

        XCTAssertEqual(
            try Data(contentsOf: fixture.agents.appendingPathComponent("worker.toml")),
            Data("\u{FEFF}model = \"gpt-5.6-luna\"\nmodel_reasoning_effort = \"max\"\n".utf8)
        )
    }

    func testManagedTOMLRejectsControlsInvalidUnicodeAndPreservesZeroWrites() throws {
        let invalidValues = ["\"\\u0000\"", "\"\\u0008\"", "\"\\u000C\"", "\"\\uD800\"", "\"\\U00110000\"", "\"\\b\""]
        for value in invalidValues {
            let fixture = try Fixture(
                roleFiles: ["worker": "model = \(value)\nmodel_reasoning_effort = \"low\"\n"],
                overlay: alphaOverlay(efforts: ["max"])
            )
            defer { fixture.cleanup() }
            let recorder = WriteRecorder()
            XCTAssertThrowsError(try makeManager(fixture) { recorder.record($0) }.apply(
                policy: policy(role: "worker"),
                catalog: [gptDescriptor],
                installedRoleIDs: ["worker"]
            ))
            XCTAssertTrue(recorder.targets.isEmpty, "invalid token (value) performed a write")
        }
    }

    func testTableHeaderCommentBracketAndEscapedTripleQuotesKeepNestedKeysUntouched() throws {
        let original = "model = \"old\"\nmodel_reasoning_effort = \"low\"\n[permissions] # ]\nmodel = \"nested\"\ndeveloper_instructions = \"\"\"escaped \\\"\"\" text\"\"\"\n"
        let fixture = try Fixture(roleFiles: ["worker": original], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }
        try makeManager(fixture).apply(
            policy: policy(role: "worker"),
            catalog: [gptDescriptor],
            installedRoleIDs: ["worker"]
        )
        let rewritten = try String(contentsOf: fixture.agents.appendingPathComponent("worker.toml"), encoding: .utf8)
        XCTAssertTrue(rewritten.contains("[permissions] # ]\nmodel = \"nested\""))
        XCTAssertTrue(rewritten.contains("escaped \\\"\"\" text"))
    }

    func testTripleDelimitersInsideOrdinaryQuotedStringsDoNotOpenMultilineContext() throws {
        let original = "model = \"old\"\nmodel_reasoning_effort = \"low\"\ncustom_basic = \"'''\"\ncustom_literal = '\"\"\"'\n"
        let fixture = try Fixture(roleFiles: ["worker": original], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }

        try makeManager(fixture).apply(
            policy: policy(role: "worker"),
            catalog: [gptDescriptor],
            installedRoleIDs: ["worker"]
        )

        let expected = "model = \"gpt-5.6-luna\"\nmodel_reasoning_effort = \"max\"\ncustom_basic = \"'''\"\ncustom_literal = '\"\"\"'\n"
        XCTAssertEqual(
            try Data(contentsOf: fixture.agents.appendingPathComponent("worker.toml")),
            Data(expected.utf8)
        )
    }

    func testExtraBracketTableHeadersFailBeforeWrites() throws {
        let originals = [
            "model = \"old\"\nmodel_reasoning_effort = \"low\"\n[permissions]]\nmodel = \"nested\"\n",
            "model = \"old\"\nmodel_reasoning_effort = \"low\"\n[[[permissions]]]\nmodel = \"nested\"\n",
        ]
        for original in originals {
            let fixture = try Fixture(roleFiles: ["worker": original], overlay: alphaOverlay(efforts: ["max"]))
            defer { fixture.cleanup() }
            let recorder = WriteRecorder()

            XCTAssertThrowsError(try makeManager(fixture) { recorder.record($0) }.apply(
                policy: policy(role: "worker"),
                catalog: [gptDescriptor],
                installedRoleIDs: ["worker"]
            )) { error in
                guard case .malformedRole("worker") = error as? CodexSubagentPolicyManagerError else {
                    return XCTFail("Expected malformed role, got \(error)")
                }
            }
            XCTAssertTrue(recorder.targets.isEmpty)
            XCTAssertEqual(
                try Data(contentsOf: fixture.agents.appendingPathComponent("worker.toml")),
                Data(original.utf8)
            )
        }
    }

    func testManagedKeyNamespaceCollisionsFailBeforeWrites() throws {
        let originals = [
            "model.foo = \"nested\"\nmodel = \"old\"\nmodel_reasoning_effort = \"low\"\n",
            "model = \"old\"\nmodel_reasoning_effort = \"low\"\n[model]\nvalue = \"nested\"\n",
            "model_reasoning_effort.bar = \"nested\"\nmodel = \"old\"\nmodel_reasoning_effort = \"low\"\n",
            "model = \"old\"\nmodel_reasoning_effort = \"low\"\n[model_reasoning_effort.foo]\nvalue = \"nested\"\n",
        ]
        for original in originals {
            let fixture = try Fixture(roleFiles: ["worker": original], overlay: alphaOverlay(efforts: ["max"]))
            defer { fixture.cleanup() }
            let recorder = WriteRecorder()

            XCTAssertThrowsError(try makeManager(fixture) { recorder.record($0) }.apply(
                policy: policy(role: "worker"),
                catalog: [gptDescriptor],
                installedRoleIDs: ["worker"]
            )) { error in
                guard case .malformedRole("worker") = error as? CodexSubagentPolicyManagerError else {
                    return XCTFail("Expected malformed role, got \(error)")
                }
            }
            XCTAssertTrue(recorder.targets.isEmpty)
            XCTAssertEqual(
                try Data(contentsOf: fixture.agents.appendingPathComponent("worker.toml")),
                Data(original.utf8)
            )
        }
    }

    func testManagedNamespaceCollisionParsingRejectsSpacedAndQuotedVariants() throws {
        let originals = [
            "model . foo = \"nested\"\nmodel = \"old\"\nmodel_reasoning_effort = \"low\"\n",
            "\"model\".foo = \"nested\"\nmodel = \"old\"\nmodel_reasoning_effort = \"low\"\n",
            "\"model\" . foo = \"nested\"\nmodel = \"old\"\nmodel_reasoning_effort = \"low\"\n",
            "model_reasoning_effort . foo = \"nested\"\nmodel = \"old\"\nmodel_reasoning_effort = \"low\"\n",
            "\"model_reasoning_effort\".foo = \"nested\"\nmodel = \"old\"\nmodel_reasoning_effort = \"low\"\n",
            "\"model_reasoning_effort\" . foo = \"nested\"\nmodel = \"old\"\nmodel_reasoning_effort = \"low\"\n",
        ]
        for original in originals {
            let fixture = try Fixture(roleFiles: ["worker": original], overlay: alphaOverlay(efforts: ["max"]))
            defer { fixture.cleanup() }
            let recorder = WriteRecorder()

            XCTAssertThrowsError(try makeManager(fixture) { recorder.record($0) }.apply(
                policy: policy(role: "worker"),
                catalog: [gptDescriptor],
                installedRoleIDs: ["worker"]
            )) { error in
                guard case .malformedRole("worker") = error as? CodexSubagentPolicyManagerError else {
                    return XCTFail("Expected malformed role, got \(error)")
                }
            }
            XCTAssertTrue(recorder.targets.isEmpty)
            XCTAssertEqual(
                try Data(contentsOf: fixture.agents.appendingPathComponent("worker.toml")),
                Data(original.utf8)
            )
        }
    }

    func testUnrelatedDottedTopLevelKeyRemainsValidAndBytePreserved() throws {
        let original = "custom.foo = \"nested\"\nmodel = \"old\"\nmodel_reasoning_effort = \"low\"\n"
        let fixture = try Fixture(roleFiles: ["worker": original], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }

        try makeManager(fixture).apply(
            policy: policy(role: "worker"),
            catalog: [gptDescriptor],
            installedRoleIDs: ["worker"]
        )

        let expected = "custom.foo = \"nested\"\nmodel = \"gpt-5.6-luna\"\nmodel_reasoning_effort = \"max\"\n"
        XCTAssertEqual(
            try Data(contentsOf: fixture.agents.appendingPathComponent("worker.toml")),
            Data(expected.utf8)
        )
    }

    func testEscapedQuotedManagedKeysAndNamespacesFailBeforeWrites() throws {
        let originals = [
            "\"mo\\u0064el\" = \"old\"\nmodel_reasoning_effort = \"low\"\n",
            "'model' = \"old\"\nmodel_reasoning_effort = \"low\"\n",
            "\"mo\\u0064el\".foo = \"nested\"\nmodel = \"old\"\nmodel_reasoning_effort = \"low\"\n",
            "model = \"old\"\nmodel_reasoning_effort = \"low\"\n[\"mo\\u0064el\"]\nvalue = \"nested\"\n",
            "model = \"old\"\nmodel_reasoning_effort = \"low\"\n[\"model_reasoning_eff\\u006frt\"]\nvalue = \"nested\"\n",
        ]
        for original in originals {
            let fixture = try Fixture(roleFiles: ["worker": original], overlay: alphaOverlay(efforts: ["max"]))
            defer { fixture.cleanup() }
            let recorder = WriteRecorder()

            XCTAssertThrowsError(try makeManager(fixture) { recorder.record($0) }.apply(
                policy: policy(role: "worker"),
                catalog: [gptDescriptor],
                installedRoleIDs: ["worker"]
            )) { error in
                guard case .malformedRole("worker") = error as? CodexSubagentPolicyManagerError else {
                    return XCTFail("Expected malformed role, got \(error)")
                }
            }
            XCTAssertTrue(recorder.targets.isEmpty)
            XCTAssertEqual(
                try Data(contentsOf: fixture.agents.appendingPathComponent("worker.toml")),
                Data(original.utf8)
            )
        }
    }

    func testMalformedQuotedManagedKeysFailClosedBeforeWrites() throws {
        let originals = [
            "\"model = \"old\"\nmodel_reasoning_effort = \"low\"\n",
            "model = \"old\"\nmodel_reasoning_effort = \"low\"\n[\"model]\nvalue = \"nested\"\n",
            "model = \"old\"\nmodel_reasoning_effort = \"low\"\n[\"model\\\"]\nvalue = \"nested\"\n",
        ]
        for original in originals {
            let fixture = try Fixture(roleFiles: ["worker": original], overlay: alphaOverlay(efforts: ["max"]))
            defer { fixture.cleanup() }
            let recorder = WriteRecorder()

            XCTAssertThrowsError(try makeManager(fixture) { recorder.record($0) }.apply(
                policy: policy(role: "worker"),
                catalog: [gptDescriptor],
                installedRoleIDs: ["worker"]
            )) { error in
                guard case .malformedRole("worker") = error as? CodexSubagentPolicyManagerError else {
                    return XCTFail("Expected malformed role, got \(error)")
                }
            }
            XCTAssertTrue(recorder.targets.isEmpty)
            XCTAssertEqual(
                try Data(contentsOf: fixture.agents.appendingPathComponent("worker.toml")),
                Data(original.utf8)
            )
        }
    }

    func testUnrelatedQuotedKeysRemainValidAndBytePreserved() throws {
        let original = "\"custom\" = \"value\"\n\"custom\".foo = \"nested\"\nmodel = \"old\"\nmodel_reasoning_effort = \"low\"\n[\"custom\"]\nmodel = \"nested\"\n"
        let fixture = try Fixture(roleFiles: ["worker": original], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }

        try makeManager(fixture).apply(
            policy: policy(role: "worker"),
            catalog: [gptDescriptor],
            installedRoleIDs: ["worker"]
        )

        let expected = "\"custom\" = \"value\"\n\"custom\".foo = \"nested\"\nmodel = \"gpt-5.6-luna\"\nmodel_reasoning_effort = \"max\"\n[\"custom\"]\nmodel = \"nested\"\n"
        XCTAssertEqual(
            try Data(contentsOf: fixture.agents.appendingPathComponent("worker.toml")),
            Data(expected.utf8)
        )
    }

    func testManagedCommentOnlyKeysFailClosedBeforeWrites() throws {
        let originals = [
            "\"model\" # comment\nmodel_reasoning_effort = \"low\"\n",
            "\"model_reasoning_effort\" # comment\nmodel = \"old\"\n",
            "model # comment\nmodel_reasoning_effort = \"low\"\n",
            "model_reasoning_effort # comment\nmodel = \"old\"\n",
        ]
        for original in originals {
            let fixture = try Fixture(roleFiles: ["worker": original], overlay: alphaOverlay(efforts: ["max"]))
            defer { fixture.cleanup() }
            let recorder = WriteRecorder()

            XCTAssertThrowsError(try makeManager(fixture) { recorder.record($0) }.apply(
                policy: policy(role: "worker"),
                catalog: [gptDescriptor],
                installedRoleIDs: ["worker"]
            )) { error in
                guard case .malformedRole("worker") = error as? CodexSubagentPolicyManagerError else {
                    return XCTFail("Expected malformed role, got \(error)")
                }
            }
            XCTAssertTrue(recorder.targets.isEmpty)
            XCTAssertEqual(
                try Data(contentsOf: fixture.agents.appendingPathComponent("worker.toml")),
                Data(original.utf8)
            )
        }
    }

    func testUnrelatedCommentOnlyKeysRemainBytePreserved() throws {
        let original = "custom # comment\n\"custom\" # quoted comment\nmodel = \"old\"\nmodel_reasoning_effort = \"low\"\n"
        let fixture = try Fixture(roleFiles: ["worker": original], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }

        try makeManager(fixture).apply(
            policy: policy(role: "worker"),
            catalog: [gptDescriptor],
            installedRoleIDs: ["worker"]
        )

        let expected = "custom # comment\n\"custom\" # quoted comment\nmodel = \"gpt-5.6-luna\"\nmodel_reasoning_effort = \"max\"\n"
        XCTAssertEqual(
            try Data(contentsOf: fixture.agents.appendingPathComponent("worker.toml")),
            Data(expected.utf8)
        )
    }

    func testMalformedUTF8RoleDataFailsBeforeWrites() throws {
        let fixture = try Fixture(roleFiles: ["worker": validRole], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }
        let original = Data([0x6D, 0x6F, 0x64, 0x65, 0x6C, 0x20, 0x3D, 0x20, 0xFF, 0x0A])
        let roleURL = fixture.agents.appendingPathComponent("worker.toml")
        try original.write(to: roleURL)
        let recorder = WriteRecorder()

        XCTAssertThrowsError(try makeManager(fixture) { recorder.record($0) }.apply(
            policy: policy(role: "worker"),
            catalog: [gptDescriptor],
            installedRoleIDs: ["worker"]
        )) { error in
            guard case .malformedRole("worker") = error as? CodexSubagentPolicyManagerError else {
                return XCTFail("Expected malformed role, got \(error)")
            }
        }
        XCTAssertTrue(recorder.targets.isEmpty)
        XCTAssertEqual(try Data(contentsOf: roleURL), original)
    }

    func testMetadataFailureAfterHookAbortsBeforeAnyReplacement() throws {
        let fixture = try Fixture(roleFiles: ["worker": validRole], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }
        let box = MetadataFailureBox()
        let live = CodexSubagentPolicyFileSystem.live
        let manager = CodexSubagentPolicyManager(
            codexHome: fixture.codexHome,
            catalogOverlayURL: fixture.overlay,
            fileSystem: CodexSubagentPolicyFileSystem(
                readData: live.readData,
                metadata: { url in
                    if box.shouldFail(url) { throw TestFailure.injected }
                    return try live.metadata(url)
                },
                atomicReplace: live.atomicReplace
            ),
            mutationHook: { stage in
                if case .beforeWrite(.role("worker")) = stage { box.enable() }
            }
        )
        XCTAssertThrowsError(try manager.apply(
            policy: policy(role: "worker"),
            catalog: [gptDescriptor],
            installedRoleIDs: ["worker"]
        ))
        XCTAssertEqual(try Data(contentsOf: fixture.agents.appendingPathComponent("worker.toml")), Data(validRole.utf8))
    }

    func testAlphaUltraRequiresNativeMaxAndOwnsOnlySyntheticEntry() throws {
        let missingMax = try Fixture(roleFiles: ["worker": validRole], overlay: alphaOverlay(efforts: ["high"]))
        defer { missingMax.cleanup() }
        let recorder = WriteRecorder()
        XCTAssertThrowsError(try makeManager(missingMax) { recorder.record($0) }.apply(
            policy: policy(role: "worker", alphaUltra: true),
            catalog: [gptDescriptor, alphaDescriptor],
            installedRoleIDs: ["worker"]
        )) { error in
            guard case .overlay(.missingNativeMax) = error as? CodexSubagentPolicyManagerError else {
                return XCTFail("Expected missing native max, got \(error)")
            }
        }
        XCTAssertTrue(recorder.targets.isEmpty)

        let overlay = #"{"models":[{"slug":"x-preview-f-free","supported_reasoning_levels":[{"effort":"max"},{"effort":"ultra","codexswap_synthetic_ultra":true},{"effort":"ultra","description":"native"}]}]}"#
        let fixture = try Fixture(roleFiles: ["worker": validRole], overlay: overlay)
        defer { fixture.cleanup() }
        try makeManager(fixture).apply(
            policy: policy(role: "worker", alphaUltra: false),
            catalog: [gptDescriptor, alphaDescriptor],
            installedRoleIDs: ["worker"]
        )
        let object = try overlayObject(fixture)
        let levels = try XCTUnwrap((object["models"] as? [[String: Any]])?.first?["supported_reasoning_levels"] as? [[String: Any]])
        XCTAssertEqual(levels.compactMap { $0["effort"] as? String }, ["max", "ultra"])
        XCTAssertNil(levels.first(where: { $0["codexswap_synthetic_ultra"] as? Bool == true }))
    }

    func testSyntheticMarkerMustBeTrueOnUltra() throws {
        let overlay = #"{"models":[{"slug":"x-preview-f-free","supported_reasoning_levels":[{"effort":"max"},{"effort":"ultra","codexswap_synthetic_ultra":false}]}]}"#
        let fixture = try Fixture(roleFiles: ["worker": validRole], overlay: overlay)
        defer { fixture.cleanup() }
        let recorder = WriteRecorder()

        XCTAssertThrowsError(try makeManager(fixture) { recorder.record($0) }.apply(
            policy: policy(role: "worker", alphaUltra: false),
            catalog: [gptDescriptor, alphaDescriptor],
            installedRoleIDs: ["worker"]
        )) { error in
            guard case .overlay(.invalidSyntheticMarker) = error as? CodexSubagentPolicyManagerError else {
                return XCTFail("Expected invalid synthetic marker, got \(error)")
            }
        }
        XCTAssertTrue(recorder.targets.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.overlay), Data(overlay.utf8))
    }

    func testConcurrentAppliesAreSerialized() throws {
        let fixture = try Fixture(roleFiles: ["worker": validRole], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }
        let probe = ConcurrencyProbe()
        let manager = makeManager(fixture) { stage in
            if case .beforeWrite(.role("worker")) = stage { probe.enter() }
            if case .afterWrite(.role("worker")) = stage { probe.leave() }
        }
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            try? manager.apply(
                policy: policy(role: "worker", effort: index == 0 ? .max : .high),
                catalog: [gptDescriptor],
                installedRoleIDs: ["worker"]
            )
        }
        XCTAssertEqual(probe.maxActive, 1)
    }

    func testDuplicateTopLevelManagedKeyIsRejectedBeforeAnyWrite() throws {
        let fixture = try Fixture(
            roleFiles: ["worker": "model = \"old\"\nmodel = \"second\"\nmodel_reasoning_effort = \"low\"\n"],
            overlay: alphaOverlay(efforts: ["max"])
        )
        defer { fixture.cleanup() }
        let recorder = WriteRecorder()
        let manager = makeManager(fixture) { recorder.record($0) }

        XCTAssertThrowsError(try manager.apply(
            policy: policy(role: "worker"),
            catalog: [gptDescriptor],
            installedRoleIDs: ["worker"]
        )) { error in
            guard case .duplicateManagedKey(let roleID, let key) = error as? CodexSubagentPolicyManagerError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(roleID, "worker")
            XCTAssertEqual(key, "model")
        }
        XCTAssertTrue(recorder.targets.isEmpty)
    }

    func testExistingManagedValuesMustBeSingleLineBasicOrLiteralStringTokens() throws {
        let invalidValues = [
            "",
            "\"unterminated",
            "\"\"\"multi\"\"\"",
            "[\"array\"]",
            "{ key = \"table\" }",
            "42",
            "bare-value",
            "\"valid\" trailing",
        ]
        for value in invalidValues {
            let fixture = try Fixture(
                roleFiles: ["worker": "model = \(value)\nmodel_reasoning_effort = \"low\"\n"],
                overlay: alphaOverlay(efforts: ["max"])
            )
            let recorder = WriteRecorder()
            let manager = makeManager(fixture) { recorder.record($0) }
            defer { fixture.cleanup() }

            XCTAssertThrowsError(try manager.apply(
                policy: policy(role: "worker"),
                catalog: [gptDescriptor],
                installedRoleIDs: ["worker"]
            )) { error in
                guard case .malformedRole("worker") = error as? CodexSubagentPolicyManagerError else {
                    return XCTFail("Expected malformed role for value \(value), got \(error)")
                }
            }
            XCTAssertTrue(recorder.targets.isEmpty)
        }
    }

    func testValidEscapedBasicAndLiteralManagedValuesAreAccepted() throws {
        let original = "model = \"old\\\"quoted\" # preserve comment\nmodel_reasoning_effort = 'low'\n"
        let fixture = try Fixture(roleFiles: ["worker": original], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }

        try makeManager(fixture).apply(
            policy: policy(role: "worker"),
            catalog: [gptDescriptor],
            installedRoleIDs: ["worker"]
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.agents.appendingPathComponent("worker.toml")),
            "model = \"gpt-5.6-luna\" # preserve comment\nmodel_reasoning_effort = \"max\"\n"
        )
    }

    func testUnsafeIDsSymlinksAndMissingRolesAreRejectedWithoutEscapingCodexHome() throws {
        let fixture = try Fixture(roleFiles: ["worker": validRole], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }
        let manager = makeManager(fixture)

        for unsafe in ["", ".", "..", "../escape", "nested/role", "space role", "ümlaut"] {
            XCTAssertThrowsError(try manager.apply(
                policy: policy(role: unsafe),
                catalog: [gptDescriptor],
                installedRoleIDs: [unsafe]
            )) { error in
                guard case .unsafeRoleID(unsafe) = error as? CodexSubagentPolicyManagerError else {
                    return XCTFail("Expected unsafe ID for '\(unsafe)', got \(error)")
                }
            }
        }

        XCTAssertThrowsError(try manager.apply(
            policy: policy(role: "missing"),
            catalog: [gptDescriptor],
            installedRoleIDs: ["missing"]
        )) { error in
            guard case .missingRole("missing") = error as? CodexSubagentPolicyManagerError else {
                return XCTFail("Expected missing role, got \(error)")
            }
        }

        try FileManager.default.removeItem(at: fixture.agents.appendingPathComponent("worker.toml"))
        try FileManager.default.createSymbolicLink(
            at: fixture.agents.appendingPathComponent("worker.toml"),
            withDestinationURL: fixture.root.appendingPathComponent("outside.toml")
        )
        try Data(validRole.utf8).write(to: fixture.root.appendingPathComponent("outside.toml"))
        XCTAssertThrowsError(try manager.apply(
            policy: policy(role: "worker"),
            catalog: [gptDescriptor],
            installedRoleIDs: ["worker"]
        )) { error in
            guard case .symlinkRole("worker") = error as? CodexSubagentPolicyManagerError else {
                return XCTFail("Expected symlink role, got \(error)")
            }
        }
    }

    func testSymlinkedAgentsDirectoryAndOverlayAreRejected() throws {
        let fixture = try Fixture(roleFiles: ["worker": validRole], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }
        let outsideAgents = fixture.root.appendingPathComponent("outside-agents", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideAgents, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: fixture.agents)
        try FileManager.default.createSymbolicLink(at: fixture.agents, withDestinationURL: outsideAgents)

        XCTAssertThrowsError(try makeManager(fixture).apply(
            policy: policy(role: "worker"),
            catalog: [gptDescriptor],
            installedRoleIDs: ["worker"]
        )) { error in
            guard case .symlinkAgentsDirectory = error as? CodexSubagentPolicyManagerError else {
                return XCTFail("Expected symlinked agents directory, got \(error)")
            }
        }

        // Restore the real agents directory, then replace the overlay with a
        // symbolic link and ensure no role file is written.
        try FileManager.default.removeItem(at: fixture.agents)
        try FileManager.default.createDirectory(at: fixture.agents, withIntermediateDirectories: true)
        try Data(validRole.utf8).write(to: fixture.agents.appendingPathComponent("worker.toml"))
        let outsideOverlay = fixture.root.appendingPathComponent("outside-overlay.json")
        try Data(alphaOverlay(efforts: ["max"]).utf8).write(to: outsideOverlay)
        try FileManager.default.removeItem(at: fixture.overlay)
        try FileManager.default.createSymbolicLink(at: fixture.overlay, withDestinationURL: outsideOverlay)

        XCTAssertThrowsError(try makeManager(fixture).apply(
            policy: policy(role: "worker", alphaUltra: true),
            catalog: [gptDescriptor, alphaDescriptor],
            installedRoleIDs: ["worker"]
        )) { error in
            guard case .overlay(.symlink) = error as? CodexSubagentPolicyManagerError else {
                return XCTFail("Expected symlinked overlay, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: fixture.agents.appendingPathComponent("worker.toml")), validRole)
    }

    func testOverlayParentSymlinkIsRejectedEvenWhenOverlayURLIsOutsideCodexHome() throws {
        let fixture = try Fixture(roleFiles: ["worker": validRole], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }
        let realParent = fixture.root.appendingPathComponent("real-overlay-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: true)
        let realOverlay = realParent.appendingPathComponent("luna-v2.json")
        try Data(alphaOverlay(efforts: ["max"]).utf8).write(to: realOverlay)
        let symlinkParent = fixture.root.appendingPathComponent("symlink-overlay-parent", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkParent, withDestinationURL: realParent)
        let overlayURL = symlinkParent.appendingPathComponent("luna-v2.json")
        let manager = CodexSubagentPolicyManager(
            codexHome: fixture.codexHome,
            catalogOverlayURL: overlayURL
        )

        XCTAssertThrowsError(try manager.apply(
            policy: policy(role: "worker", alphaUltra: true),
            catalog: [gptDescriptor, alphaDescriptor],
            installedRoleIDs: ["worker"]
        )) { error in
            guard case .overlay(.symlink) = error as? CodexSubagentPolicyManagerError else {
                return XCTFail("Expected symlinked overlay parent, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: fixture.agents.appendingPathComponent("worker.toml")), validRole)
    }

    func testAgentsDirectorySwapToIdenticalExternalRoleIsRejectedAndExternalBytesStayUntouched() throws {
        let fixture = try Fixture(roleFiles: ["worker": validRole], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }
        let externalAgents = fixture.root.appendingPathComponent("external-agents", isDirectory: true)
        try FileManager.default.createDirectory(at: externalAgents, withIntermediateDirectories: true)
        let externalRole = externalAgents.appendingPathComponent("worker.toml")
        try Data(validRole.utf8).write(to: externalRole)
        let manager = makeManager(fixture) { stage in
            guard case .beforeWrite(.role("worker")) = stage else { return }
            try FileManager.default.removeItem(at: fixture.agents)
            try FileManager.default.createSymbolicLink(at: fixture.agents, withDestinationURL: externalAgents)
        }

        XCTAssertThrowsError(try manager.apply(
            policy: policy(role: "worker"),
            catalog: [gptDescriptor],
            installedRoleIDs: ["worker"]
        )) { error in
            guard case .symlinkAgentsDirectory = error as? CodexSubagentPolicyManagerError else {
                return XCTFail("Expected swapped agents directory rejection, got (error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: externalRole), Data(validRole.utf8))
    }

    func testOverlayParentSwapToIdenticalExternalOverlayIsRejectedAndExternalBytesStayUntouched() throws {
        let fixture = try Fixture(roleFiles: ["worker": validRole], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }
        let managedParent = fixture.root.appendingPathComponent("managed-overlay", isDirectory: true)
        let externalParent = fixture.root.appendingPathComponent("external-overlay", isDirectory: true)
        try FileManager.default.createDirectory(at: managedParent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalParent, withIntermediateDirectories: true)
        let managedOverlay = managedParent.appendingPathComponent("luna-v2.json")
        let externalOverlay = externalParent.appendingPathComponent("luna-v2.json")
        let originalOverlay = alphaOverlay(efforts: ["max"])
        try Data(originalOverlay.utf8).write(to: managedOverlay)
        try Data(originalOverlay.utf8).write(to: externalOverlay)
        let manager = CodexSubagentPolicyManager(
            codexHome: fixture.codexHome,
            catalogOverlayURL: managedOverlay,
            mutationHook: { stage in
                guard case .beforeWrite(.overlay) = stage else { return }
                try FileManager.default.removeItem(at: managedParent)
                try FileManager.default.createSymbolicLink(at: managedParent, withDestinationURL: externalParent)
            }
        )

        XCTAssertThrowsError(try manager.apply(
            policy: policy(role: "worker", alphaUltra: true),
            catalog: [gptDescriptor, alphaDescriptor],
            installedRoleIDs: ["worker"]
        )) { error in
            guard case .overlay(.symlink) = error as? CodexSubagentPolicyManagerError else {
                return XCTFail("Expected swapped overlay parent rejection, got (error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: externalOverlay), Data(originalOverlay.utf8))
        XCTAssertEqual(try String(contentsOf: fixture.agents.appendingPathComponent("worker.toml")), validRole)
    }

    func testLiveAtomicReplaceDoesNotCreateMissingParentDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexswap-policy-missing-parent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missingParent = root.appendingPathComponent("missing", isDirectory: true)
        let target = missingParent.appendingPathComponent("role.toml")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingParent.path))

        XCTAssertThrowsError(try CodexSubagentPolicyFileSystem.live.atomicReplace(Data("new".utf8), target, 0o600))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingParent.path))
    }

    func testValidatorFailureProducesZeroWritesAndParentConfigRemainsByteIdentical() throws {
        let fixture = try Fixture(
            roleFiles: ["worker": validRole],
            overlay: alphaOverlay(efforts: ["max"])
        )
        defer { fixture.cleanup() }
        let parentConfig = fixture.codexHome.appendingPathComponent("config.toml")
        let parentBytes = Data("model = \"gpt-5.6-sol\"\nmodel_reasoning_effort = \"high\"\n".utf8)
        try parentBytes.write(to: parentConfig)
        let recorder = WriteRecorder()
        let manager = makeManager(fixture) { recorder.record($0) }

        XCTAssertThrowsError(try manager.apply(
            policy: SubagentModelPolicy(eligibleModelIDs: [], roleAssignments: []),
            catalog: [gptDescriptor],
            installedRoleIDs: ["worker"]
        )) { error in
            guard case .validationFailed(let issues) = error as? CodexSubagentPolicyManagerError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(issues.contains { $0.code == .noEligibleModels })
        }
        XCTAssertTrue(recorder.targets.isEmpty)
        XCTAssertEqual(try Data(contentsOf: parentConfig), parentBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.agents.appendingPathComponent("worker.toml")), Data(validRole.utf8))
    }

    func testOverlayPreservesUnknownRootModelKeysAndUnrelatedModels() throws {
        let overlay = #"""
        {
          "unknown_root": {"keep": [1, true, null]},
          "unknown_number": 9007199254740991,
          "unknown_decimal": 12345.6789,
          "models": [
            {"slug": "unrelated", "unknown_model": {"k": "v", "numeric": 314159.2653}, "supported_reasoning_levels": [{"effort": "high"}]},
            {"slug": "x-preview-f-free", "display_name": "Alpha", "unknown_alpha": ["preserve"], "supported_reasoning_levels": [{"effort": "max", "provider": "native"}]}
          ]
        }
        """#
        let fixture = try Fixture(roleFiles: ["worker": validRole], overlay: overlay)
        defer { fixture.cleanup() }

        try makeManager(fixture).apply(
            policy: policy(role: "worker", model: "gpt-5.6-luna", effort: .max, alphaUltra: true),
            catalog: [gptDescriptor, alphaDescriptor],
            installedRoleIDs: ["worker"]
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.overlay)) as? [String: Any])
        let unknownKeep = ((object["unknown_root"] as? [String: Any])?["keep"] as? [Any]) ?? []
        XCTAssertEqual(unknownKeep.count, 3)
        XCTAssertEqual((unknownKeep.first as? NSNumber)?.intValue, 1)
        XCTAssertEqual((object["unknown_number"] as? NSNumber)?.stringValue, "9007199254740991")
        XCTAssertEqual((object["unknown_decimal"] as? NSNumber)?.doubleValue ?? 0, 12345.6789, accuracy: 0.0000001)
        let models = try XCTUnwrap(object["models"] as? [[String: Any]])
        XCTAssertEqual((models[0]["unknown_model"] as? [String: Any])?["k"] as? String, "v")
        XCTAssertEqual(((models[0]["unknown_model"] as? [String: Any])?["numeric"] as? NSNumber)?.doubleValue ?? 0, 314159.2653, accuracy: 0.0000001)
        XCTAssertEqual((models[1]["unknown_alpha"] as? [String])?.first, "preserve")
        XCTAssertEqual((models[1]["supported_reasoning_levels"] as? [[String: Any]])?.first?["provider"] as? String, "native")
        XCTAssertEqual((models[1]["supported_reasoning_levels"] as? [[String: Any]])?.map { $0["effort"] as? String }, ["max", "ultra"])
        let alphaLevels = try XCTUnwrap(models[1]["supported_reasoning_levels"] as? [[String: Any]])
        XCTAssertEqual(alphaLevels.last?["codexswap_synthetic_ultra"] as? Bool, true)
    }

    func testMissingBridgedCatalogModelIsSynthesizedFromAlphaTemplate() throws {
        let overlay = #"""
        {
          "root_unknown": {"keep": "root"},
          "models": [
            {
              "slug": "x-preview-f-free",
              "display_name": "Raw Alpha",
              "description": "template description",
              "default_reasoning_level": "max",
              "supported_reasoning_levels": [{"effort": "max", "description": "native", "provider": "raw"}],
              "visibility": "list",
              "list": true,
              "supported_in_api": true,
              "priority": 42,
              "upgrade": "template-upgrade",
              "availability": "ga",
              "required_schema": {"keep": true},
              "tool": {"keep": ["tool"]},
              "prompt": {"keep": "prompt"}
            }
          ]
        }
        """#
        let fixture = try Fixture(roleFiles: ["worker": validRole], overlay: overlay)
        defer { fixture.cleanup() }
        let future = CodexModelDescriptor(
            modelID: "future-bridge",
            displayName: "Future Bridge",
            supportedReasoningEfforts: [.high],
            providerFamily: .bridged
        )

        try makeManager(fixture).apply(
            policy: policy(role: "worker", model: "future-bridge", effort: .high),
            catalog: [future],
            installedRoleIDs: ["worker"]
        )

        let object = try overlayObject(fixture)
        let models = try XCTUnwrap(object["models"] as? [[String: Any]])
        let synthesized = try XCTUnwrap(models.first { $0["slug"] as? String == "future-bridge" })
        XCTAssertEqual(synthesized["display_name"] as? String, "Future Bridge")
        XCTAssertEqual(synthesized["description"] as? String, "CodexSwap bridged model")
        XCTAssertEqual(synthesized["default_reasoning_level"] as? String, "high")
        XCTAssertEqual((synthesized["supported_reasoning_levels"] as? [[String: Any]])?.map { $0["effort"] as? String }, ["high"])
        XCTAssertEqual(synthesized["visibility"] as? String, "list")
        XCTAssertEqual(synthesized["list"] as? Bool, true)
        XCTAssertEqual(synthesized["supported_in_api"] as? Bool, true)
        XCTAssertEqual((synthesized["priority"] as? NSNumber)?.intValue, 0)
        XCTAssertTrue(synthesized["upgrade"] is NSNull)
        XCTAssertTrue(synthesized["availability_nux"] is NSNull)
        XCTAssertEqual((synthesized["additional_speed_tiers"] as? [Any])?.isEmpty, true)
        XCTAssertEqual((synthesized["service_tiers"] as? [Any])?.isEmpty, true)
        XCTAssertEqual((synthesized["required_schema"] as? [String: Any])?["keep"] as? Bool, true)
        XCTAssertEqual((synthesized["tool"] as? [String: Any])?["keep"] as? [String], ["tool"])
        XCTAssertEqual((synthesized["prompt"] as? [String: Any])?["keep"] as? String, "prompt")
        XCTAssertEqual((object["root_unknown"] as? [String: Any])?["keep"] as? String, "root")
    }

    func testMissingBridgedCatalogModelUsesFirstRawTemplateWhenAlphaIsAbsent() throws {
        let overlay = #"{"models":[{"slug":"gpt-5.6-luna","supported_reasoning_levels":[{"effort":"max"}],"required_schema":{"keep":true}}]}"#
        let fixture = try Fixture(roleFiles: ["worker": validRole], overlay: overlay)
        defer { fixture.cleanup() }
        let future = CodexModelDescriptor(
            modelID: "future-bridge",
            displayName: "Future Bridge",
            supportedReasoningEfforts: [.high],
            providerFamily: .bridged
        )

        try makeManager(fixture).apply(
            policy: policy(role: "worker", model: "future-bridge", effort: .high),
            catalog: [future],
            installedRoleIDs: ["worker"]
        )

        let models = try XCTUnwrap(try overlayObject(fixture)["models"] as? [[String: Any]])
        let synthesized = try XCTUnwrap(models.first { $0["slug"] as? String == "future-bridge" })
        XCTAssertEqual(synthesized["display_name"] as? String, "Future Bridge")
        XCTAssertEqual((synthesized["supported_reasoning_levels"] as? [[String: Any]])?.map { $0["effort"] as? String }, ["high"])
        XCTAssertEqual((synthesized["required_schema"] as? [String: Any])?["keep"] as? Bool, true)
    }

    func testAbsentAlphaIsSynthesizedFromFirstRawTemplateForUltra() throws {
        let overlay = #"""
        {
          "root_unknown": {"keep": true},
          "models": [
            {
              "slug": "gpt-5.6-luna",
              "display_name": "Raw Luna",
              "required_schema": {"keep": "schema"},
              "supported_reasoning_levels": [{"effort": "max", "raw": true}]
            }
          ]
        }
        """#
        let fixture = try Fixture(roleFiles: ["worker": validRole], overlay: overlay)
        defer { fixture.cleanup() }

        try makeManager(fixture).apply(
            policy: policy(role: "worker", model: SubagentPolicyValidator.alphaModelID, effort: .ultra, alphaUltra: true),
            catalog: [gptDescriptor, alphaDescriptor],
            installedRoleIDs: ["worker"]
        )

        let models = try XCTUnwrap(try overlayObject(fixture)["models"] as? [[String: Any]])
        let alpha = try XCTUnwrap(models.first { $0["slug"] as? String == SubagentPolicyValidator.alphaModelID })
        XCTAssertEqual(alpha["display_name"] as? String, "Alpha")
        XCTAssertEqual(alpha["description"] as? String, "CodexSwap bridged model")
        XCTAssertEqual(alpha["default_reasoning_level"] as? String, "low")
        let levels = try XCTUnwrap(alpha["supported_reasoning_levels"] as? [[String: Any]])
        XCTAssertEqual(levels.map { $0["effort"] as? String }, ["low", "high", "max", "ultra"])
        XCTAssertEqual(levels.last?["codexswap_synthetic_ultra"] as? Bool, true)
        XCTAssertEqual((alpha["required_schema"] as? [String: Any])?["keep"] as? String, "schema")
        XCTAssertEqual((levels.first?["raw"] as? Bool), nil)
        XCTAssertEqual((models.first { $0["slug"] as? String == "gpt-5.6-luna" }?["slug"] as? String), "gpt-5.6-luna")
    }

    func testMissingBridgedTemplateFailsClosedAndParentMismatchBlocksBeforeWrites() throws {
        let future = CodexModelDescriptor(
            modelID: "future-bridge",
            displayName: "Future Bridge",
            supportedReasoningEfforts: [.high],
            providerFamily: .bridged
        )
        let emptyFixture = try Fixture(roleFiles: ["worker": validRole], overlay: #"{"models":[]}"#)
        defer { emptyFixture.cleanup() }
        let emptyRecorder = WriteRecorder()
        XCTAssertThrowsError(try makeManager(emptyFixture) { emptyRecorder.record($0) }.apply(
            policy: policy(role: "worker", model: "future-bridge", effort: .high),
            catalog: [future],
            installedRoleIDs: ["worker"]
        )) { error in
            guard case .overlay(.missingAlphaModel) = error as? CodexSubagentPolicyManagerError else {
                return XCTFail("Expected missing template failure, got \(error)")
            }
        }
        XCTAssertTrue(emptyRecorder.targets.isEmpty)
        XCTAssertEqual(try String(contentsOf: emptyFixture.agents.appendingPathComponent("worker.toml")), validRole)

        let mismatchFixture = try Fixture(roleFiles: ["worker": validRole], overlay: alphaOverlay(efforts: ["max"]))
        defer { mismatchFixture.cleanup() }
        let mismatchRecorder = WriteRecorder()
        XCTAssertThrowsError(try makeManager(mismatchFixture) { mismatchRecorder.record($0) }.apply(
            policy: policy(role: "worker", model: "future-bridge", effort: .high),
            catalog: [future],
            installedRoleIDs: ["worker"],
            parentProviderFamily: .openAI
        )) { error in
            guard case .validationFailed(let issues) = error as? CodexSubagentPolicyManagerError else {
                return XCTFail("Expected parent mismatch validation failure, got \(error)")
            }
            XCTAssertTrue(issues.contains { $0.code == .parentProviderMismatch })
        }
        XCTAssertTrue(mismatchRecorder.targets.isEmpty)
    }

    func testNativeAndSyntheticUltraEnableDisableAreSafeAndIdempotent() throws {
        let nativeFixture = try Fixture(roleFiles: ["worker": validRole], overlay: alphaOverlay(efforts: ["max", "ultra"]))
        defer { nativeFixture.cleanup() }
        try makeManager(nativeFixture).apply(
            policy: policy(role: "worker", alphaUltra: true),
            catalog: [gptDescriptor, alphaDescriptor],
            installedRoleIDs: ["worker"]
        )
        let native = try overlayObject(nativeFixture)
        let nativeAlpha = try XCTUnwrap((native["models"] as? [[String: Any]])?.first)
        XCTAssertNil(nativeAlpha["codexswap_synthetic_ultra"])
        XCTAssertEqual((nativeAlpha["supported_reasoning_levels"] as? [[String: Any]])?.count, 2)

        let syntheticFixture = try Fixture(roleFiles: ["worker": validRole], overlay: alphaOverlay(efforts: ["max"]))
        defer { syntheticFixture.cleanup() }
        let recorder = WriteRecorder()
        let syntheticManager = makeManager(syntheticFixture) { recorder.record($0) }
        let syntheticPolicy = policy(role: "worker", alphaUltra: true)
        try syntheticManager.apply(policy: syntheticPolicy, catalog: [gptDescriptor, alphaDescriptor], installedRoleIDs: ["worker"])
        let firstWriteCount = recorder.targets.count
        try syntheticManager.apply(policy: syntheticPolicy, catalog: [gptDescriptor, alphaDescriptor], installedRoleIDs: ["worker"])
        XCTAssertEqual(recorder.targets.count, firstWriteCount, "An already synthetic overlay must be idempotent")

        try makeManager(syntheticFixture).apply(
            policy: policy(role: "worker", alphaUltra: false),
            catalog: [gptDescriptor, alphaDescriptor],
            installedRoleIDs: ["worker"]
        )
        let disabled = try overlayObject(syntheticFixture)
        let disabledAlpha = try XCTUnwrap((disabled["models"] as? [[String: Any]])?.first)
        XCTAssertNil(disabledAlpha["codexswap_synthetic_ultra"])
        XCTAssertEqual((disabledAlpha["supported_reasoning_levels"] as? [[String: Any]])?.map { $0["effort"] as? String }, ["max"])
    }

    func testOverlayNoOpsPreserveOriginalBytesAndPerformNoWrites() throws {
        let role = "model = \"gpt-5.6-luna\"\nmodel_reasoning_effort = \"max\"\n"
        let cases: [(String, Bool)] = [
            (alphaOverlay(efforts: ["max", "ultra"]), true),
            (alphaOverlay(efforts: ["max", "ultra"]), false),
            (alphaOverlayWithMarker(efforts: ["max", "ultra"]), true),
        ]
        for (overlay, alphaUltraEnabled) in cases {
            let fixture = try Fixture(roleFiles: ["worker": role], overlay: overlay)
            let originalOverlay = try Data(contentsOf: fixture.overlay)
            let recorder = WriteRecorder()
            let manager = makeManager(fixture) { recorder.record($0) }
            defer { fixture.cleanup() }

            try manager.apply(
                policy: policy(role: "worker", alphaUltra: alphaUltraEnabled),
                catalog: [gptDescriptor, alphaDescriptor],
                installedRoleIDs: ["worker"]
            )
            XCTAssertEqual(try Data(contentsOf: fixture.overlay), originalOverlay)
            XCTAssertTrue(recorder.targets.isEmpty)
        }
    }

    func testOverlayMissingDuplicateAndMalformedAlphaFailBeforeRoleWrites() throws {
        let cases: [(String, CodexSubagentPolicyOverlayError)] = [
            (#"{"models":[{"slug":"other","supported_reasoning_levels":[]}]}"#, .missingAlphaModel),
            (#"{"models":[{"slug":"x-preview-f-free","supported_reasoning_levels":[]},{"slug":"x-preview-f-free","supported_reasoning_levels":[] }]}"#, .duplicateAlphaEntries),
            (#"{"models":[{"slug":"x-preview-f-free","supported_reasoning_levels":[{"effort":"max"},{"effort":"max"}]}]}"#, .invalidEffortArray),
            (#"{"models":[{"slug":"x-preview-f-free","supported_reasoning_levels":{}}]}"#, .invalidEffortArray),
        ]
        for (overlay, expected) in cases {
            let fixture = try Fixture(roleFiles: ["worker": validRole], overlay: overlay)
            let recorder = WriteRecorder()
            let manager = makeManager(fixture) { recorder.record($0) }
            defer { fixture.cleanup() }
            XCTAssertThrowsError(try manager.apply(
                policy: policy(role: "worker", alphaUltra: true),
                catalog: [gptDescriptor, alphaDescriptor],
                installedRoleIDs: ["worker"]
            )) { error in
                guard case .overlay(let actual) = error as? CodexSubagentPolicyManagerError else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(actual, expected)
            }
            XCTAssertTrue(recorder.targets.isEmpty)
        }
    }

    func testMalformedOverlayRootModelsOrUnrelatedEntryFailsBeforeRoleWrite() throws {
        let validAlpha = #"{"slug":"x-preview-f-free","supported_reasoning_levels":[{"effort":"max"}]}"#
        let malformedOverlays = [
            "[]",
            #"{"models":{}}"#,
            "{\"models\":[17,\(validAlpha)]}",
            "{\"models\":[{\"slug\":\"other\",\"supported_reasoning_levels\":7},\(validAlpha)]}",
        ]
        for overlay in malformedOverlays {
            let fixture = try Fixture(roleFiles: ["worker": validRole], overlay: overlay)
            let recorder = WriteRecorder()
            let manager = makeManager(fixture) { recorder.record($0) }
            defer { fixture.cleanup() }

            XCTAssertThrowsError(try manager.apply(
                policy: policy(role: "worker", alphaUltra: true),
                catalog: [gptDescriptor, alphaDescriptor],
                installedRoleIDs: ["worker"]
            )) { error in
                guard case .overlay(.malformed) = error as? CodexSubagentPolicyManagerError else {
                    return XCTFail("Expected malformed overlay for \(overlay), got \(error)")
                }
            }
            XCTAssertTrue(recorder.targets.isEmpty)
            XCTAssertEqual(try String(contentsOf: fixture.agents.appendingPathComponent("worker.toml")), validRole)
        }
    }

    func testDisablingUltraWithoutAlphaIsABytePreservingNoOp() throws {
        let originalOverlay = #"{"models":[{"slug":"other","supported_reasoning_levels":[{"effort":"high"}]}],"unknown": [1,2,3]}"#
        let fixture = try Fixture(roleFiles: ["worker": validRole], overlay: originalOverlay)
        defer { fixture.cleanup() }

        try makeManager(fixture).apply(
            policy: policy(role: "worker", alphaUltra: false),
            catalog: [gptDescriptor],
            installedRoleIDs: ["worker"]
        )
        XCTAssertEqual(try Data(contentsOf: fixture.overlay), Data(originalOverlay.utf8))
    }

    func testPreservesPermissionsAndDetectsExternalEditsImmediatelyBeforeReplacement() throws {
        let fixture = try Fixture(roleFiles: ["worker": validRole], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o640)], ofItemAtPath: fixture.agents.appendingPathComponent("worker.toml").path)
        let recorder = WriteRecorder()
        let manager = makeManager(fixture) { stage in
            recorder.record(stage)
            if case .beforeWrite(.role("worker")) = stage {
                try Data("external edit\n".utf8).write(to: fixture.agents.appendingPathComponent("worker.toml"))
            }
        }

        XCTAssertThrowsError(try manager.apply(
            policy: policy(role: "worker"),
            catalog: [gptDescriptor],
            installedRoleIDs: ["worker"]
        )) { error in
            guard case .externalEdit(.role("worker")) = error as? CodexSubagentPolicyManagerError else {
                return XCTFail("Expected external edit, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: fixture.agents.appendingPathComponent("worker.toml")), "external edit\n")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: fixture.agents.appendingPathComponent("worker.toml").path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
    }

    func testSuccessfulChangedFilesPreserveOriginalPOSIXPermissions() throws {
        let fixture = try Fixture(roleFiles: ["worker": validRole], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }
        let roleURL = fixture.agents.appendingPathComponent("worker.toml")
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o640)], ofItemAtPath: roleURL.path)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: fixture.overlay.path)

        try makeManager(fixture).apply(
            policy: policy(role: "worker", alphaUltra: true),
            catalog: [gptDescriptor, alphaDescriptor],
            installedRoleIDs: ["worker"]
        )
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: roleURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: fixture.overlay.path)[.posixPermissions] as? NSNumber)?.intValue, 0o644)
    }

    func testLaterWriteFailureRollsBackEveryEarlierFileByteForByteInReverseOrder() throws {
        let roleA = "model = \"old-a\"\nmodel_reasoning_effort = \"low\"\n"
        let roleB = "model = \"old-b\"\nmodel_reasoning_effort = \"low\"\n"
        let fixture = try Fixture(roleFiles: ["a": roleA, "b": roleB], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }
        let recorder = WriteRecorder()
        let manager = makeManager(fixture) { stage in
            recorder.record(stage)
            if case .beforeWrite(.role("b")) = stage { throw TestFailure.injected }
        }
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-luna"],
            roleAssignments: [
                SubagentRoleAssignment(roleID: "a", modelID: "gpt-5.6-luna", reasoningEffort: .max),
                SubagentRoleAssignment(roleID: "b", modelID: "gpt-5.6-luna", reasoningEffort: .max),
            ]
        )

        XCTAssertThrowsError(try manager.apply(policy: policy, catalog: [gptDescriptor], installedRoleIDs: ["b", "a"])) { error in
            guard case .writeFailed(.role("b")) = error as? CodexSubagentPolicyManagerError else {
                return XCTFail("Expected typed write failure, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: fixture.agents.appendingPathComponent("a.toml")), roleA)
        XCTAssertEqual(try String(contentsOf: fixture.agents.appendingPathComponent("b.toml")), roleB)
        XCTAssertEqual(recorder.targets, [.role("a"), .role("b")])
    }

    func testRollbackConflictPreservesExternalBytesAndReportsRecoveryError() throws {
        let roleA = "model = \"old-a\"\nmodel_reasoning_effort = \"low\"\n"
        let roleB = "model = \"old-b\"\nmodel_reasoning_effort = \"low\"\n"
        let fixture = try Fixture(roleFiles: ["a": roleA, "b": roleB], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }
        let manager = makeManager(fixture) { stage in
            if case .beforeWrite(.role("b")) = stage {
                try Data("external-b\n".utf8).write(to: fixture.agents.appendingPathComponent("b.toml"))
                throw TestFailure.injected
            }
            if case .beforeRollback(.role("a")) = stage {
                try Data("external-a\n".utf8).write(to: fixture.agents.appendingPathComponent("a.toml"))
            }
        }
        let policy = SubagentModelPolicy(
            eligibleModelIDs: ["gpt-5.6-luna"],
            roleAssignments: [
                SubagentRoleAssignment(roleID: "a", modelID: "gpt-5.6-luna", reasoningEffort: .max),
                SubagentRoleAssignment(roleID: "b", modelID: "gpt-5.6-luna", reasoningEffort: .max),
            ]
        )

        XCTAssertThrowsError(try manager.apply(policy: policy, catalog: [gptDescriptor], installedRoleIDs: ["a", "b"])) { error in
            guard case .transactionRecoveryFailed(.role(let target)) = error as? CodexSubagentPolicyManagerError else {
                return XCTFail("Expected recovery error naming only role kind, got \(error)")
            }
            XCTAssertTrue(target == "a" || target == "b")
        }
        XCTAssertEqual(try String(contentsOf: fixture.agents.appendingPathComponent("a.toml")), "external-a\n")
        XCTAssertEqual(try String(contentsOf: fixture.agents.appendingPathComponent("b.toml")), "external-b\n")
    }

    func testWritesAreDeterministicByRoleIDThenOverlay() throws {
        let fixture = try Fixture(roleFiles: ["z": validRole, "a": validRole], overlay: alphaOverlay(efforts: ["max"]))
        defer { fixture.cleanup() }
        let recorder = WriteRecorder()
        let manager = makeManager(fixture) { recorder.record($0) }
        try manager.apply(
            policy: SubagentModelPolicy(
                eligibleModelIDs: ["gpt-5.6-luna"],
                roleAssignments: [
                    SubagentRoleAssignment(roleID: "z", modelID: "gpt-5.6-luna", reasoningEffort: .max),
                    SubagentRoleAssignment(roleID: "a", modelID: "gpt-5.6-luna", reasoningEffort: .max),
                ],
                alphaUltraEnabled: true
            ),
            catalog: [gptDescriptor, alphaDescriptor],
            installedRoleIDs: ["z", "a"]
        )
        XCTAssertEqual(recorder.targets, [.role("a"), .role("z"), .overlay])
    }

    private enum TestFailure: Error { case injected }

    private var validRole: String {
        "model = \"gpt-old\"\nmodel_reasoning_effort = \"low\"\n"
    }

    private var gptDescriptor: CodexModelDescriptor {
        CodexModelDescriptor(
            modelID: "gpt-5.6-luna",
            displayName: "GPT-5.6 Luna",
            supportedReasoningEfforts: [.low, .high, .max],
            providerFamily: .openAI
        )
    }

    private var alphaDescriptor: CodexModelDescriptor {
        CodexModelDescriptor(
            modelID: "x-preview-f-free",
            displayName: "Alpha",
            supportedReasoningEfforts: [.low, .high, .max, .ultra],
            providerFamily: .bridged,
            syntheticUltra: true
        )
    }

    private func policy(
        role: String,
        model: String = "gpt-5.6-luna",
        effort: CodexReasoningEffort = .max,
        alphaUltra: Bool = false
    ) -> SubagentModelPolicy {
        SubagentModelPolicy(
            eligibleModelIDs: [model],
            roleAssignments: [SubagentRoleAssignment(roleID: role, modelID: model, reasoningEffort: effort)],
            alphaUltraEnabled: alphaUltra
        )
    }

    private func makeManager(
        _ fixture: Fixture,
        hook: @escaping CodexSubagentPolicyManager.MutationHook = { _ in }
    ) -> CodexSubagentPolicyManager {
        CodexSubagentPolicyManager(
            codexHome: fixture.codexHome,
            catalogOverlayURL: fixture.overlay,
            mutationHook: hook
        )
    }

    private func alphaOverlay(efforts: [String]) -> String {
        let levels = efforts.map { "{\"effort\":\"\($0)\",\"description\":\"native\"}" }.joined(separator: ",")
        return "{\"models\":[{\"slug\":\"x-preview-f-free\",\"display_name\":\"Alpha\",\"supported_reasoning_levels\":[\(levels)]}],\"root_unknown\":{\"keep\":true}}"
    }

    private func alphaOverlayWithMarker(efforts: [String]) -> String {
        let levels = efforts.map { effort in
            if effort == "ultra" {
                return "{\"effort\":\"ultra\",\"description\":\"synthetic\",\"codexswap_synthetic_ultra\":true}"
            }
            return "{\"effort\":\"\(effort)\",\"description\":\"native\"}"
        }.joined(separator: ",")
        return "{\"models\":[{\"slug\":\"x-preview-f-free\",\"display_name\":\"Alpha\",\"supported_reasoning_levels\":[\(levels)]}]}"
    }

    private func overlayObject(_ fixture: Fixture) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.overlay)) as? [String: Any])
    }
}
