import Foundation
import IncrementalParsing
import LanguageTooling
import PascalConformance
@testable import PascalLanguage
import Testing

@Suite("Pascal scoped tooling trial")
struct PascalScopeTests {
    private let source = PascalConformanceCorpus.scopedTooling

    @Test func nestedScopesBindParametersAndShadowing() async throws {
        let analysis = try await PascalLanguageSession().analyze(
            .init(text: source, revision: .init(1)))
        #expect(analysis.parsing.accepted)
        let model = analysis.semantics
        #expect(model.diagnostics.isEmpty)
        #expect(model.scopes.count == 4)
        #expect(model.symbols.filter { $0.kind == .parameter }.map(\.name) == ["value", "delta"])

        let global = try #require(model.symbols.first { $0.name == "count" })
        let local = try #require(model.symbols.last { $0.name == "count" })
        #expect(global.id != local.id)
        #expect(global.scopeID != local.scopeID)
        let index = model.toolingIndex
        #expect(index.symbol(at: offset("count := value"))?.id.rawValue == local.id)
        #expect(index.symbol(at: offset("count := count + delta"))?.id.rawValue == local.id)
        #expect(index.symbol(at: offset("count := 1"))?.id.rawValue == global.id)
        #expect(index.symbol(at: offset("count := 2"))?.id.rawValue == global.id)
        let innerVisible = index.visibleSymbols(at: offset("count := count + delta"))
        #expect(innerVisible.filter { $0.name == "count" }.count == 1)
        #expect(innerVisible.contains { $0.name == "value" })
        #expect(innerVisible.contains { $0.name == "delta" })
        let outside = index.visibleSymbols(at: offset("count := 2"))
        #expect(!outside.contains { ["value", "delta", "Inner"].contains($0.name) })
    }

    @Test func providerQueriesRespectRoutineBoundaries() async throws {
        let session = PascalProviderSession(documentURI: "file:///scopes.pas")
        _ = try await session.analyze(.init(text: source, revision: .init(1)), change: nil)
        let map = SourceLineMap(source)
        let innerPosition = map.position(of: offset("count := count + delta"))
        let parameterPosition = map.position(of: offset("delta end"))
        let outsidePosition = map.position(of: offset("count := 2"))
        let localDefinition = try await session.definition(at: innerPosition)
        #expect(localDefinition?.uri == "file:///scopes.pas")
        #expect(localDefinition?.range.start == map.position(of: offset("var count: integer; procedure Inner") + 4))
        let parameterHover = try await session.hover(at: parameterPosition)
        #expect(parameterHover?.contents == "parameter delta")
        let innerCompletion = try await session.completions(at: innerPosition)
        #expect(innerCompletion.contains { $0.label == "delta" })
        let outsideCompletion = try await session.completions(at: outsidePosition)
        #expect(!outsideCompletion.contains { ["delta", "value", "Inner"].contains($0.label) })
        let localReferences = try await session.references(at: innerPosition)
        #expect(localReferences.count == 5)
    }

    @Test func duplicatesAreDiagnosedOnlyWithinTheirOwnScope() async throws {
        let text = "program Demo; var x: integer; procedure P(x: integer; X: integer); begin end; begin end."
        let analysis = try await PascalLanguageSession().analyze(.init(text: text, revision: .init(1)))
        #expect(analysis.parsing.accepted)
        #expect(analysis.semantics.diagnostics.count == 1)
        #expect(analysis.semantics.diagnostics.first?.message == "Duplicate Pascal declaration 'X'.")
    }

    @Test func compoundCaseAndRecordEndsDoNotCloseRoutineScope() async throws {
        let text = "program Demo; procedure P(x: integer); type rec = record x: integer; y: integer end; "
            + "var local: integer; begin case x of 1: begin local := x end end; local := x end; begin P(1) end."
        let analysis = try await PascalLanguageSession().analyze(.init(text: text, revision: .init(1)))
        #expect(analysis.parsing.accepted)
        #expect(analysis.semantics.diagnostics.isEmpty)
        #expect(analysis.semantics.symbols.map(\.name) == ["Demo", "P", "x", "rec", "local"])
        let finalUse = (text as NSString).range(of: "local := x", options: .backwards).location
        #expect(analysis.semantics.toolingIndex.visibleSymbols(at: finalUse).contains { $0.name == "x" })
        #expect(!analysis.semantics.toolingIndex.visibleSymbols(at: text.utf16.count).contains { $0.name == "local" })
    }

    @Test func functionResultIsAWriteAndRecursiveCallIsACall() async throws {
        let text = "program Demo; function F(n: integer): integer; begin if n = 0 then F := 1 else F := F(n - 1) end; begin F(2) end."
        let analysis = try await PascalLanguageSession().analyze(.init(text: text, revision: .init(1)))
        #expect(analysis.parsing.accepted)
        let function = try #require(analysis.semantics.symbols.first { $0.kind == .function })
        let roles = analysis.semantics.references.filter { $0.symbolID == function.id }.map(\.role)
        #expect(roles.filter { $0 == .write }.count == 2)
        #expect(roles.filter { $0 == .call }.count == 2)
    }

    @Test func groupedVarParametersUseParameterHighlighting() async throws {
        let text = "program Demo; var a: integer; procedure P(var x,y: integer; z: integer); begin x := y + z end; begin P(a,a,1) end."
        let analysis = try await PascalLanguageSession().analyze(.init(text: text, revision: .init(1)))
        #expect(analysis.parsing.accepted)
        #expect(analysis.semantics.symbols.filter { $0.kind == .parameter }.map(\.name) == ["x", "y", "z"])
        let session = PascalProviderSession()
        let providerAnalysis = try await session.analyze(.init(text: text, revision: .init(1)), change: nil)
        #expect(providerAnalysis.tokens.filter {
            $0.classification == "parameter" && $0.modifiers.contains("declaration")
        }.count == 3)
        let encoded = try await session.semanticTokens()
        let parameterType = try #require(ToolingSemanticTokenType.allCases.firstIndex(of: .parameter))
        #expect(stride(from: 3, to: encoded.data.count, by: 5).filter {
            encoded.data[$0] == parameterType
        }.count == 6)
    }

    @Test func rebindingAnUnchangedReferenceIsRebuiltAndMatchesCleanAnalysis() async throws {
        let initial = SourceSnapshot(text: source, revision: .init(1))
        let declaration = (source as NSString).range(of: "var count: integer; procedure Inner")
        let change = try SourceEdit(
            baseRevision: initial.revision,
            range: .init(location: declaration.location + 4, length: 5),
            replacement: "total").applying(to: initial)
        let session = PascalLanguageSession()
        let before = try await session.analyze(initial)
        let edited = try await session.analyze(change.after, change: change)
        let clean = try await PascalLanguageSession().analyze(change.after)
        #expect(edited.parsing.accepted)
        let use = offset("count := value")
        let old = try #require(before.semantics.references.first { $0.range.location == use })
        let new = try #require(edited.semantics.references.first { $0.range.location == use })
        #expect(old.tokenID == new.tokenID)
        #expect(old.symbolID != new.symbolID)
        #expect(edited.semantics.reuseMetrics.rebuiltReferenceCount >= 4)
        #expect(edited.semantics.reuseMetrics.reusedReferenceCount > 0)
        // Clean runs allocate different token IDs. Compare resolved declaration ranges.
        for reference in edited.semantics.references {
            let cleanSymbol = clean.semantics.toolingIndex.symbol(at: reference.range.location)
            let editedSymbol = edited.semantics.toolingIndex.symbol(at: reference.range.location)
            #expect(cleanSymbol?.name == editedSymbol?.name)
            #expect(cleanSymbol?.declarationRange == editedSymbol?.declarationRange)
        }
        #expect(edited.semantics.semanticTokens == clean.semantics.semanticTokens)
        #expect(edited.semantics.diagnostics == clean.semantics.diagnostics)
    }

    @Test func incompleteRoutineKeepsParametersVisibleAtEndOfDocument() throws {
        // Query the semantic projection directly to avoid conflating parser repair with binding.
        let text = "program Demo; procedure P(value: integer); begin value := 1  "
        let tokens = PascalLexer().tokenize(.init(text: text, revision: .init(1))).tokens
        var analyzer = PascalIncrementalSemanticAnalyzer()
        let model = analyzer.analyze(revision: .init(1), tokens: tokens, reusingPrevious: false)
        #expect(model.toolingIndex.visibleSymbols(at: text.utf16.count).contains { $0.name == "value" })
    }

    @Test func recoveredHeadingStillSupportsToolingAndRepair() async throws {
        let heading = "Outer(value: integer)"
        let insertion = offset(heading) + heading.utf16.count
        let broken = (source as NSString).replacingCharacters(
            in: NSRange(location: insertion, length: 1), with: "")
        let snapshot = SourceSnapshot(text: broken, revision: .init(1))
        let session = PascalProviderSession()
        let analysis = try await session.analyze(snapshot, change: nil)
        #expect(!analysis.diagnostics.isEmpty)
        #expect(!analysis.recoveryEdits.isEmpty)
        let use = (broken as NSString).range(of: "delta end").location
        let hover = try await session.hover(at: SourceLineMap(broken).position(of: use))
        #expect(hover?.contents == "parameter delta")
        let change = try SourceEdit(
            baseRevision: snapshot.revision,
            range: .init(location: insertion, length: 0),
            replacement: ";").applying(to: snapshot)
        let repaired = try await session.analyze(change.after, change: change)
        #expect(repaired.diagnostics.isEmpty)
        #expect(repaired.recoveryEdits.isEmpty)
    }

    @Test func prefixEditRelocatesRangesAndPreservesRoutineScopeIdentity() async throws {
        let snapshot = SourceSnapshot(text: source, revision: .init(1))
        let change = try SourceEdit(
            baseRevision: snapshot.revision,
            range: .init(location: 0, length: 0),
            replacement: "{ notes 😀 }\n").applying(to: snapshot)
        let session = PascalLanguageSession()
        let before = try await session.analyze(snapshot)
        let edited = try await session.analyze(change.after, change: change)
        let clean = try await PascalLanguageSession().analyze(change.after)
        #expect(edited.parsing.accepted)
        #expect(edited.semantics.scopes.map(\.id) == before.semantics.scopes.map(\.id))
        #expect(edited.semantics.semanticTokens == clean.semantics.semanticTokens)
        let original = try #require(before.semantics.symbols.first { $0.name == "delta" })
        let relocated = try #require(edited.semantics.symbols.first { $0.name == "delta" })
        #expect(original.id == relocated.id)
        #expect(relocated.declarationRange.location
            == original.declarationRange.location + "{ notes 😀 }\n".utf16.count)
    }

    private func offset(_ needle: String) -> Int {
        (source as NSString).range(of: needle).location
    }
}
