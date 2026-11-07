import Foundation
import IncrementalParsing
import PascalConformance
import PascalLanguage

public enum PascalProductCampaign {
    public static let campaignProtocol = IncrementalMeasurementProtocol(
        id: "pascal-language-kit-trial-v1",
        warmupIterations: 1,
        measurementIterations: 3)

    public static let scenarios = definitions.map(\.scenario)

    public static func run(
        environment: IncrementalMeasurementEnvironment = .pascalCurrent,
        protocol protocolValue: IncrementalMeasurementProtocol = campaignProtocol,
        clock: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) async throws -> IncrementalMeasurementReport {
        let byID = Dictionary(uniqueKeysWithValues: definitions.map {
            ($0.scenario.id, $0)
        })
        return try await IncrementalMeasurementRunner.run(
            protocol: protocolValue,
            environment: environment,
            artifact: PascalLanguageKit.bundled.artifact.incrementalIdentity,
            scenarios: scenarios,
            clock: clock
        ) { scenario, _ in
            guard let definition = byID[scenario.id] else {
                throw IncrementalMeasurementError.invalidReport(
                    "Unknown Pascal campaign scenario \(scenario.id).")
            }
            let measured = try await execute(definition)
            let cleanSession = PascalProvider().makeSession()
            let clean = try await cleanSession.analyze(measured.snapshot)
            guard let evidence = measured.analysis.evidence(
                for: definition.operation) else {
                throw IncrementalMeasurementError.invalidReport(
                    "Missing Pascal \(definition.operation) evidence.")
            }
            return IncrementalMeasuredOperation(
                evidence: evidence,
                equivalentToCleanRun: projection(measured.analysis) == projection(clean))
        }
    }

    private struct Definition {
        let scenario: IncrementalMeasurementScenario
        let source: String
        let editNeedle: String?
        let replacement: String
        let operation: String
    }

    private struct Execution {
        let snapshot: SourceSnapshot
        let analysis: LanguageProviderAnalysis
    }

    private struct Projection: Equatable {
        let artifact: IncrementalArtifactIdentity?
        let tokens: [LanguageProviderToken]
        let diagnostics: [LanguageProviderDiagnostic]
        let recoveryEdits: [LanguageProviderRecoveryEdit]
    }

    private static let definitions: [Definition] = [
        .init(
            scenario: .init(
                id: "accepted.minimal",
                title: "Accepted minimal Pascal program"),
            source: PascalConformanceCorpus.accepted[0],
            editNeedle: nil,
            replacement: "",
            operation: "parsing"),
        .init(
            scenario: .init(
                id: "rejected.missing-end",
                title: "Recovered incomplete Pascal program"),
            source: PascalConformanceCorpus.rejected[1],
            editNeedle: nil,
            replacement: "",
            operation: "parsing"),
        .init(
            scenario: .init(
                id: "edit.lexer.identifier",
                title: "Restart and converge after an identifier edit"),
            source: PascalConformanceCorpus.mutationSeeds[0],
            editNeedle: "Count",
            replacement: "Counter",
            operation: "lexing"),
        .init(
            scenario: .init(
                id: "edit.earley.disclosure",
                title: "Disclose full Pascal Earley chart rebuild"),
            source: PascalConformanceCorpus.mutationSeeds[1],
            editNeedle: "10",
            replacement: "20",
            operation: "parsing"),
    ]

    private static func execute(_ definition: Definition) async throws -> Execution {
        let session = PascalProvider().makeSession()
        let initial = SourceSnapshot(text: definition.source, revision: .init(1))
        guard let needle = definition.editNeedle else {
            return .init(
                snapshot: initial,
                analysis: try await session.analyze(initial))
        }
        _ = try await session.analyze(initial)
        let range = (definition.source as NSString).range(of: needle)
        guard range.location != NSNotFound else {
            throw IncrementalMeasurementError.invalidReport(
                "Pascal campaign edit anchor not found: \(needle).")
        }
        let change = try SourceEdit(
            baseRevision: initial.revision,
            range: .init(location: range.location, length: range.length),
            replacement: definition.replacement
        ).applying(to: initial)
        return .init(
            snapshot: change.after,
            analysis: try await session.analyze(change.after, change: change))
    }

    private static func projection(
        _ analysis: LanguageProviderAnalysis
    ) -> Projection {
        .init(
            artifact: analysis.artifact,
            tokens: analysis.tokens,
            diagnostics: analysis.diagnostics,
            recoveryEdits: analysis.recoveryEdits)
    }
}

public extension IncrementalMeasurementEnvironment {
    static var pascalCurrent: Self {
        let processInfo = ProcessInfo.processInfo
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return .init(
            hostID: processInfo.environment["PASCAL_MEASUREMENT_HOST_ID"]
                ?? processInfo.hostName,
            operatingSystem: processInfo.operatingSystemVersionString,
            architecture: architecture,
            swiftVersion: processInfo.environment["PASCAL_MEASUREMENT_SWIFT_VERSION"]
                ?? "swift-6.1-or-newer")
    }
}
