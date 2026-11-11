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

    @Test func incrementalTokenizerAndEarleyParserReuseNativeState() async throws {
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
        #expect(analysis.parsing.metrics.evidence.strategy == .incremental)
        #expect(analysis.parsing.metrics.evidence.measurements.first {
            $0.dimension == .chartColumns
        }?.reused ?? 0 > 0)
        #expect(analysis.parsing.metrics.evidence.measurements.first {
            $0.dimension == .chartFacts
        }?.reused ?? 0 > 0)
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
        #expect(analysis.recoveryEdits.allSatisfy {
            $0.range.location <= PascalConformanceCorpus.rejected[0].utf16.count
        })
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

    @Test func semanticTrialPublishesBindingsAndSharedToolingQueries() async throws {
        let source = "program Demo; const limit = 10; type index = 1..10; "
            + "var i: index; begin i := limit end."
        let session = PascalProviderSession(documentURI: "file:///trial.pas")
        let analysis = try await session.analyze(.init(
            text: source, revision: .init(1)), change: nil)
        let limitUse = (source as NSString).range(of: "limit", options: .backwards)
        let iUse = (source as NSString).range(of: "i :=")

        #expect(analysis.evidence(for: "semantics") != nil)
        #expect(analysis.tokens.contains {
            $0.classification == "constant" && $0.modifiers.contains("declaration")
        })
        let definition = try await session.definition(
            at: .init(line: 0, character: limitUse.location))
        let hover = try await session.hover(
            at: .init(line: 0, character: iUse.location))
        let references = try await session.references(
            at: .init(line: 0, character: limitUse.location))
        let completions = try await session.completions(
            at: .init(line: 0, character: source.utf16.count))
        let semanticTokens = try await session.semanticTokens()

        #expect(definition?.uri == "file:///trial.pas")
        #expect(definition?.range.start.character
            == (source as NSString).range(of: "limit").location)
        #expect(hover?.contents == "variable i")
        #expect(references.count == 2)
        #expect(completions.contains { $0.label.lowercased() == "limit" })
        #expect(completions.contains { $0.label.lowercased() == "index" })
        #expect(!semanticTokens.data.isEmpty)
    }

    @Test func semanticTrialReusesStableBindingsAcrossLiteralEdit() async throws {
        let source = "program Demo; const limit = 10; var i: integer; begin i := limit end."
        let initial = SourceSnapshot(text: source, revision: .init(1))
        let range = (source as NSString).range(of: "10")
        let transition = try SourceEdit(
            baseRevision: initial.revision,
            range: .init(location: range.location, length: range.length),
            replacement: "100").applying(to: initial)
        let session = PascalLanguageSession()
        _ = try await session.analyze(initial)
        let edited = try await session.analyze(
            transition.after, change: transition)

        #expect(edited.semantics.reuseMetrics.incremental)
        #expect(edited.semantics.reuseMetrics.reusedSymbolCount > 0)
        #expect(edited.semantics.reuseMetrics.reusedReferenceCount > 0)
        #expect(edited.semantics.reuseMetrics.evidence.strategy == .incremental)
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
            $0.scenarioID == "edit.earley.chart"
        }?.measurement(for: .chartColumns)?.reused ?? 0 > 0)
        #expect(report.summaries.first {
            $0.scenarioID == "edit.semantics.literal"
        }?.measurement(for: .semanticNodes)?.reused ?? 0 > 0)
    }
}
