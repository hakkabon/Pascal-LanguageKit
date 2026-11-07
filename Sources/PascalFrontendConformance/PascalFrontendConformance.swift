import Foundation
import IncrementalParsing
import PascalConformance
import PascalLanguage

public struct PascalFrontendExperimentObservation: Codable, Hashable, Sendable {
    public let caseID: String
    public let grammarFingerprint: String
    public let accepted: Bool
    public let tokenEvidence: [String]
    public let diagnostics: [String]
    public let recoveryEdits: [LanguageProviderRecoveryEdit]
}

public struct PascalFrontendExperimentReport: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2
    public let schemaVersion: Int
    public let frontendID: String
    public let observations: [PascalFrontendExperimentObservation]

    public init(
        frontendID: String,
        observations: [PascalFrontendExperimentObservation]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.frontendID = frontendID
        self.observations = observations
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct PascalCrossFrontendAgreement: Codable, Hashable, Sendable {
    public let equivalent: Bool
    public let frontends: [String]
    public let mismatchDescriptions: [String]
}

public enum PascalFrontendExperimentSuite {
    public static func run(frontendID: String) async throws
        -> PascalFrontendExperimentReport {
        let fixtures = PascalConformanceCorpus.accepted.enumerated().map {
            ("accepted-\($0.offset)", $0.element)
        } + PascalConformanceCorpus.rejected.enumerated().map {
            ("rejected-\($0.offset)", $0.element)
        }
        var observations: [PascalFrontendExperimentObservation] = []
        for (index, fixture) in fixtures.enumerated() {
            let provider = PascalProvider()
            let session = provider.makeSession()
            let analysis = try await session.analyze(.init(
                text: fixture.1,
                revision: .init(UInt64(index + 1))))
            observations.append(.init(
                caseID: fixture.0,
                grammarFingerprint: analysis.artifact?.fingerprint ?? "missing",
                accepted: analysis.diagnostics.isEmpty,
                tokenEvidence: analysis.tokens.map {
                    "\($0.classification)|\($0.range.lowerBound):\($0.range.upperBound)"
                },
                diagnostics: analysis.diagnostics.map {
                    "\($0.severity.rawValue)|\($0.range.lowerBound):\($0.range.upperBound)|\($0.message)"
                },
                recoveryEdits: analysis.recoveryEdits))
        }
        return .init(frontendID: frontendID, observations: observations)
    }

    public static func compare(
        _ reports: [PascalFrontendExperimentReport]
    ) -> PascalCrossFrontendAgreement {
        guard let baseline = reports.first else {
            return .init(
                equivalent: false,
                frontends: [],
                mismatchDescriptions: ["No reports supplied."])
        }
        var mismatches: [String] = []
        for report in reports.dropFirst() where report.observations != baseline.observations {
            mismatches.append(
                "\(report.frontendID) differs from \(baseline.frontendID).")
        }
        return .init(
            equivalent: mismatches.isEmpty,
            frontends: reports.map(\.frontendID),
            mismatchDescriptions: mismatches)
    }
}
