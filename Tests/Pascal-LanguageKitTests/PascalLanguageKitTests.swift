import Foundation
import IncrementalParsing
import LanguageTooling
import PascalConformance
import PascalFrontendConformance
@testable import PascalLanguage
import Testing

@Suite("Pascal language-kit trial")
struct PascalLanguageKitTests {
    @Test func bundledGrammarCompilesToOneLexicalAndSyntacticArtifact() throws {
        let kit = PascalLanguageKit.bundled

        #expect(kit.artifact.startSymbol == "program")
        #expect(kit.artifact.productions.count > 100)
        #expect(kit.artifact.lexicalSpecification.significantRules.count > 50)
        #expect(kit.artifact.lexicalSpecification.triviaRules.count == 4)
        #expect(kit.artifact.definition(named: "PROGRAM")?.matcher
            == .caseInsensitiveLiteral("program"))
        #expect(Set(kit.artifact.tokenDefinitions.map(\.name)).count
            == kit.artifact.tokenDefinitions.count)
    }

    @Test func lexerIsCaseInsensitiveLosslessAndDistinguishesRangeFromReal() {
        let source = "PrOgRaM p; begin {note} x := 1.25; x := 1..2 end."
        let result = PascalLexer().tokenize(.init(text: source, revision: .init(1)))

        #expect(result.diagnostics.isEmpty)
        #expect(result.reconstructedSource == source)
        #expect(result.tokens.map(\.kind.rawValue) == [
            "PROGRAM", "IDENTIFIER", "SEMICOLON", "BEGIN", "IDENTIFIER",
            "ASSIGN", "UNSIGNED_REAL", "SEMICOLON", "IDENTIFIER", "ASSIGN",
            "UNSIGNED_INTEGER", "RANGE", "UNSIGNED_INTEGER", "END", "PERIOD", "$EOF",
        ])
        #expect(result.elements.contains {
            if case .trivia("BRACE_COMMENT") = $0.kind { true } else { false }
        })
    }

    @Test func generalizedParserAcceptsAndRejectsPublishedCorpus() {
        let lexer = PascalLexer()
        let parser = PascalParser()

        for (index, source) in PascalConformanceCorpus.accepted.enumerated() {
            let snapshot = SourceSnapshot(
                text: source,
                revision: .init(UInt64(index + 1)))
            let result = parser.parse(source: source, lexed: lexer.tokenize(snapshot))
            #expect(result.accepted, "Expected accepted Pascal fixture \(index)")
            #expect(result.diagnostics.isEmpty)
        }
        for (index, source) in PascalConformanceCorpus.rejected.enumerated() {
            let snapshot = SourceSnapshot(
                text: source,
                revision: .init(UInt64(index + 100)))
            let result = parser.parse(source: source, lexed: lexer.tokenize(snapshot))
            #expect(!result.accepted, "Expected rejected Pascal fixture \(index)")
            #expect(!result.diagnostics.isEmpty)
            if index < 3 {
                #expect(result.recovered, "Expected syntax fixture \(index) to recover")
                #expect(!result.recoveryEdits.isEmpty)
                #expect(result.metrics.forestNodeCount > 0)
            } else {
                #expect(!result.recovered, "Lexical errors must not be repaired by the parser")
            }
        }
    }

    @Test func incrementalTokenizerReusesStableTokensAndParserDisclosesFallback() async throws {
        let source = PascalConformanceCorpus.mutationSeeds[0]
        let initial = SourceSnapshot(text: source, revision: .init(1))
        let range = try #require(source.range(of: "Count"))
        let utf16Range = NSRange(range, in: source)
        let change = try SourceEdit(
            baseRevision: initial.revision,
            range: .init(location: utf16Range.location, length: utf16Range.length),
            replacement: "Counter"
        ).applying(to: initial)
        let session = PascalLanguageSession()

        _ = try await session.analyze(initial)
        let analysis = try await session.analyze(change.after, change: change)

        #expect(analysis.parsing.accepted)
        #expect(analysis.lexing.metrics.incremental)
        #expect(analysis.lexing.metrics.reusedSuffixTokenCount > 0)
        #expect(analysis.parsing.metrics.evidence.strategy == .fallback)
        #expect(analysis.parsing.metrics.evidence.fallback?.code
            == "pascal.earley.fullReparse")
    }

    @Test func providerPublishesPortableAnalysis() async throws {
        let provider = PascalProvider()
        let session = provider.makeSession()
        let analysis = try await session.analyze(.init(
            text: PascalConformanceCorpus.accepted[4],
            revision: .init(7)))

        #expect(provider.descriptor.distribution == .externalLanguageKit)
        #expect(provider.descriptor.capabilities.contains(.recovery))
        #expect(analysis.languageID == "pascal")
        #expect(analysis.artifact == PascalLanguageKit.bundled.artifact.incrementalIdentity)
        #expect(analysis.diagnostics.isEmpty)
        #expect(analysis.tokens.contains { $0.classification == "keyword" })
        #expect(analysis.tokens.contains { $0.classification == "comment" })
        #expect(analysis.evidence(for: "lexing") != nil)
        #expect(analysis.evidence(for: "parsing") != nil)
    }

    @Test func providerPublishesGeneralizedRecoveryEvidence() async throws {
        let provider = PascalProvider()
        let analysis = try await provider.makeSession().analyze(.init(
            text: PascalConformanceCorpus.rejected[0],
            revision: .init(8)))

        #expect(analysis.diagnostics.allSatisfy { $0.severity == .warning })
        #expect(!analysis.recoveryEdits.isEmpty)
    }

    @Test func providerAdoptsSharedToolingSession() async throws {
        let provider = PascalProvider()
        let session = provider.makeToolingSession()
        let source = PascalConformanceCorpus.accepted[0]

        _ = try await session.analyze(.init(
            text: source,
            revision: .init(9)))
        let completions = try await session.completions(
            at: .init(line: 0, character: 0))
        let semanticTokens = try await session.semanticTokens()

        #expect(completions.contains { $0.label.lowercased() == "program" })
        #expect(!semanticTokens.data.isEmpty)
        #expect(semanticTokens.data.count.isMultiple(of: 5))
    }

    @Test func conformanceReportsAgreeAndCampaignMatchesCleanRuns() async throws {
        let first = try await PascalFrontendExperimentSuite.run(frontendID: "trial-a")
        let second = try await PascalFrontendExperimentSuite.run(frontendID: "trial-b")
        let agreement = PascalFrontendExperimentSuite.compare([first, second])
        let report = try await PascalProductCampaign.run(
            protocol: .init(
                id: "pascal-trial-test",
                warmupIterations: 0,
                measurementIterations: 1))

        #expect(agreement.equivalent)
        #expect(first.observations.count
            == PascalConformanceCorpus.accepted.count
                + PascalConformanceCorpus.rejected.count)
        #expect(report.summaries.allSatisfy { $0.correctnessFailureCount == 0 })
        #expect(report.summaries.first { $0.scenarioID == "edit.lexer.identifier" }?
            .measurement(for: .tokens)?.reused ?? 0 > 0)
        #expect(report.summaries.first {
            $0.scenarioID == "edit.earley.disclosure"
        }?.fallbackCount == 1)
    }
}
