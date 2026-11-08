import Earley_Parser
import Foundation
import Grammar
import IncrementalParsing
import Lexer
import Parser

public struct PascalParseMetrics: Sendable, Equatable {
    public let configurationCount: Int
    public let forestNodeCount: Int
    public let recoverySearchStates: Int
    public let evidence: IncrementalExecutionEvidence
}

public enum PascalRecoveryEdit: Sendable, Equatable {
    case insert(terminal: String, atToken: Int)
    case delete(terminal: String, atToken: Int)
}

public struct PascalParseResult: Sendable, Equatable {
    /// `true` only for an input accepted without repair.
    public let accepted: Bool
    public let recovered: Bool
    public let diagnostics: [PascalDiagnostic]
    public let recoveryEdits: [PascalRecoveryEdit]
    public let metrics: PascalParseMetrics
}

/// Generalized parser for the Pascal trial. Pascal's overlapping designators
/// and dangling-else shape are intentional; accepted edits use the ecosystem
/// Earley parser's live chart session, while malformed input is delegated to
/// its bounded clean recovery search.
public final class PascalParser: @unchecked Sendable {
    public let languageKit: PascalLanguageKit
    private let incrementalSession: EarleyIncrementalSession

    public init(languageKit: PascalLanguageKit = .bundled) {
        self.languageKit = languageKit
        incrementalSession = EarleyIncrementalSession(
            grammar: ecosystemGrammar(languageKit.artifact))
    }

    public func parse(
        source: String,
        lexed: PascalLexResult,
        incrementalRequest: Bool = false
    ) -> PascalParseResult {
        guard lexed.diagnostics.isEmpty else {
            return PascalParseResult(
                accepted: false,
                recovered: false,
                diagnostics: lexed.diagnostics,
                recoveryEdits: [],
                metrics: .init(
                    configurationCount: 0,
                    forestNodeCount: 0,
                    recoverySearchStates: 0,
                    evidence: parserEvidence(
                        incrementalRequest: incrementalRequest,
                        rebuilt: 0)))
        }

        do {
            let stream = try PascalTokenStream(source: source, tokens: lexed.tokens)
            let parser = Earley_Parser.EarleyParser(
                grammar: ecosystemGrammar(languageKit.artifact))
            if let live = try? incrementalSession.parse(
                stream: stream,
                tokenIdentities: stream.tokens.map {
                    EarleyTokenIdentity($0.id)
                }), live.result.isSuccessful {
                let snapshot = try live.result.sppfGraph?.portableSnapshot()
                return PascalParseResult(
                    accepted: true,
                    recovered: false,
                    diagnostics: [],
                    recoveryEdits: [],
                    metrics: .init(
                        configurationCount: live.result.bsr.count,
                        forestNodeCount: snapshot?.nodes.count ?? 0,
                        recoverySearchStates: 0,
                        evidence: live.evidence))
            }
            incrementalSession.reset()
            let recovery = try parser.parseRecovering(
                stream: stream,
                insertionCandidates: pascalRecoveryCandidates,
                policy: .init(maximumEditCost: 2, maximumExploredStates: 2_000))
            let result = recovery.parseResult
            let snapshot = try result?.sppfGraph?.portableSnapshot()
            return PascalParseResult(
                accepted: recovery.status == .accepted,
                recovered: recovery.status == .recovered,
                diagnostics: recovery.diagnostics.map {
                    pascalDiagnostic($0, source: source, tokens: stream.tokens)
                },
                recoveryEdits: recovery.recoveryEdits.map(pascalRecoveryEdit),
                metrics: .init(
                    configurationCount: result?.bsr.count ?? 0,
                    forestNodeCount: snapshot?.nodes.count ?? 0,
                    recoverySearchStates: recovery.exploredStates,
                    evidence: parserEvidence(
                        incrementalRequest: incrementalRequest,
                        rebuilt: stream.count + 1)))
        } catch {
            return PascalParseResult(
                accepted: false,
                recovered: false,
                diagnostics: [PascalDiagnostic(
                    message: "Input does not conform to the bundled Pascal grammar.",
                    range: source.utf16.count..<source.utf16.count)],
                recoveryEdits: [],
                metrics: .init(
                    configurationCount: 0,
                    forestNodeCount: 0,
                    recoverySearchStates: 0,
                    evidence: parserEvidence(
                        incrementalRequest: incrementalRequest,
                        rebuilt: 0)))
        }
    }

    public func reset() {
        incrementalSession.reset()
    }
}

public struct PascalAnalysis: Sendable, Equatable {
    public let revision: SourceRevision
    public let lexing: PascalIncrementalLexResult
    public let parsing: PascalParseResult
}

public actor PascalLanguageSession {
    private let parser: PascalParser
    private var tokenizer: PascalIncrementalTokenizer
    private var previousRevision: SourceRevision?

    public init(languageKit: PascalLanguageKit = .bundled) {
        parser = PascalParser(languageKit: languageKit)
        tokenizer = PascalIncrementalTokenizer(languageKit: languageKit)
    }

    public func analyze(
        _ snapshot: SourceSnapshot,
        change: SourceChange? = nil
    ) throws -> PascalAnalysis {
        if let change, change.after != snapshot {
            throw LanguageProviderError.inconsistentChange
        }
        let incrementalRequest = change != nil && previousRevision == change?.before.revision
        let lexing = tokenizer.tokenize(snapshot, change: change)
        let parsing = parser.parse(
            source: snapshot.text,
            lexed: lexing.lexed,
            incrementalRequest: incrementalRequest)
        previousRevision = snapshot.revision
        return PascalAnalysis(
            revision: snapshot.revision,
            lexing: lexing,
            parsing: parsing)
    }

    public func reset() {
        tokenizer.reset()
        parser.reset()
        previousRevision = nil
    }
}

private struct PascalTokenStream: TokenStream {
    let source: String
    let tokens: [PascalToken]

    init(source: String, tokens: [PascalToken]) throws {
        self.source = source
        self.tokens = tokens.filter { !$0.isEndOfInput }
        guard self.tokens.allSatisfy({ $0.kind != .invalid }),
              source.utf16.count >= (self.tokens.last?.range.upperBound ?? 0) else {
            throw PascalParserAdapterError.invalidTokenStream
        }
    }

    var count: Int { tokens.count }

    func terminal(at position: Int) throws
        -> (terminal: Terminal, range: Range<String.Index>) {
        let token = tokens[position]
        let lower = String.Index(utf16Offset: token.range.lowerBound, in: source)
        let upper = String.Index(utf16Offset: token.range.upperBound, in: source)
        return (Terminal(string: token.kind.rawValue), lower..<upper)
    }
}

private enum PascalParserAdapterError: Error {
    case invalidTokenStream
}

private func ecosystemGrammar(_ artifact: PascalGrammarArtifact) -> Grammar {
    Grammar(
        productions: artifact.productions.map { production in
            Production(
                goal: NonTerminal(name: production.lhs),
                rule: production.rhs.map { symbol in
                    switch symbol {
                    case .terminal(let name):
                        .terminal(Terminal(string: name))
                    case .nonterminal(let name):
                        .nonTerminal(NonTerminal(name: name))
                    }
                })
        },
        start: NonTerminal(name: artifact.startSymbol),
        lexicalTokens: [:])
}

private var pascalRecoveryCandidates: [Terminal] {
    [
        "SEMICOLON", "PERIOD", "END", "THEN", "DO", "RPAREN", "RBRACKET",
        "COMMA", "COLON",
    ]
}

private func pascalRecoveryEdit(_ edit: RecoveryEdit) -> PascalRecoveryEdit {
    switch edit {
    case .insert(let terminal, let index):
        .insert(terminal: terminalName(terminal), atToken: index)
    case .delete(let terminal, let index):
        .delete(terminal: terminalName(terminal), atToken: index)
    case .skip(let terminals, let index):
        .delete(
            terminal: terminals.map(terminalName).joined(separator: " "),
            atToken: index)
    }
}

private func terminalName(_ terminal: Terminal) -> String {
    if case .string(let name) = terminal { return name }
    return terminal.description
}

private func pascalDiagnostic(
    _ diagnostic: Parser.ParseDiagnostic,
    source: String,
    tokens: [PascalToken]
) -> PascalDiagnostic {
    let range: Range<Int>
    if let sourceRange = diagnostic.range {
        let nsRange = NSRange(sourceRange, in: source)
        range = nsRange.location..<(nsRange.location + nsRange.length)
    } else if let index = diagnostic.tokenIndex, index < tokens.count {
        range = tokens[index].range
    } else {
        range = source.utf16.count..<source.utf16.count
    }
    return PascalDiagnostic(message: diagnostic.message, range: range)
}

private func parserEvidence(
    incrementalRequest: Bool,
    rebuilt: Int
) -> IncrementalExecutionEvidence {
    if incrementalRequest {
        return .init(
            strategy: .fallback,
            fallback: .init(
                code: "pascal.earley.cleanFallback",
                detail: "The live parse could not accept the input; diagnostics and generalized recovery used a clean search."),
            measurements: [.init(
                dimension: .chartColumns,
                reused: 0,
                rebuilt: rebuilt,
                strategy: "full-chart")])
    }
    return .init(
        strategy: .full,
        measurements: [.init(
            dimension: .chartColumns,
            reused: 0,
            rebuilt: rebuilt,
            strategy: "full-chart")])
}
