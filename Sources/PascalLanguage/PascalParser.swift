import Earley_Parser
import Foundation
import Grammar
import IncrementalParsing
import Lexer
import Parser

public struct PascalParseMetrics: Sendable, Equatable {
    public let configurationCount: Int
    public let forestNodeCount: Int
    public let evidence: IncrementalExecutionEvidence
}

public struct PascalParseResult: Sendable, Equatable {
    public let accepted: Bool
    public let diagnostics: [PascalDiagnostic]
    public let metrics: PascalParseMetrics
}

/// Generalized baseline parser for the Pascal trial. Pascal's overlapping
/// designators and dangling-else shape are intentional; the language kit uses
/// the ecosystem Earley parser instead of hiding those conflicts in a private
/// recursive-descent implementation.
public struct PascalParser: Sendable {
    public let languageKit: PascalLanguageKit

    public init(languageKit: PascalLanguageKit = .bundled) {
        self.languageKit = languageKit
    }

    public func parse(
        source: String,
        lexed: PascalLexResult,
        incrementalRequest: Bool = false
    ) -> PascalParseResult {
        guard lexed.diagnostics.isEmpty else {
            return PascalParseResult(
                accepted: false,
                diagnostics: lexed.diagnostics,
                metrics: .init(
                    configurationCount: 0,
                    forestNodeCount: 0,
                    evidence: parserEvidence(
                        incrementalRequest: incrementalRequest,
                        rebuilt: 0)))
        }

        do {
            let stream = try PascalTokenStream(source: source, tokens: lexed.tokens)
            let parser = Earley_Parser.EarleyParser(
                grammar: ecosystemGrammar(languageKit.artifact))
            let result = try parser.parse(stream: stream)
            let snapshot = try result.sppfGraph?.portableSnapshot()
            let accepted = result.isSuccessful
            return PascalParseResult(
                accepted: accepted,
                diagnostics: accepted ? [] : [syntaxDiagnostic(tokens: stream.tokens)],
                metrics: .init(
                    configurationCount: result.bsr.count,
                    forestNodeCount: snapshot?.nodes.count ?? 0,
                    evidence: parserEvidence(
                        incrementalRequest: incrementalRequest,
                        rebuilt: stream.count + 1)))
        } catch {
            return PascalParseResult(
                accepted: false,
                diagnostics: [PascalDiagnostic(
                    message: "Input does not conform to the bundled Pascal grammar.",
                    range: source.utf16.count..<source.utf16.count)],
                metrics: .init(
                    configurationCount: 0,
                    forestNodeCount: 0,
                    evidence: parserEvidence(
                        incrementalRequest: incrementalRequest,
                        rebuilt: 0)))
        }
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

private func syntaxDiagnostic(tokens: [PascalToken]) -> PascalDiagnostic {
    let range = tokens.last?.range ?? 0..<0
    return PascalDiagnostic(
        message: "Input does not conform to the bundled Pascal grammar.",
        range: range.upperBound..<range.upperBound)
}

private func parserEvidence(
    incrementalRequest: Bool,
    rebuilt: Int
) -> IncrementalExecutionEvidence {
    if incrementalRequest {
        return .init(
            strategy: .fallback,
            fallback: .init(
                code: "pascal.earley.fullReparse",
                detail: "Tokenization was incremental; the Pascal Earley chart was rebuilt."),
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
