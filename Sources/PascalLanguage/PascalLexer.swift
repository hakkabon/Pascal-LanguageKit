import Foundation
import IncrementalParsing
import Lexer

public struct PascalTokenKind: RawRepresentable, Codable, Hashable, Sendable,
    CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let invalid = Self(rawValue: "$INVALID")
    public static let endOfFile = Self(rawValue: "$EOF")
}

public struct PascalToken: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: PascalTokenKind
    public let lexeme: String
    public let range: Range<Int>
    public let line: Int
    public let column: Int
    public let isEndOfInput: Bool
}

public enum PascalLexicalElementKind: Sendable, Equatable {
    case token(PascalTokenKind)
    case trivia(String)
    case invalid
}

public struct PascalLexicalElement: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: PascalLexicalElementKind
    public let lexeme: String
    public let range: Range<Int>
}

public struct PascalDiagnostic: Sendable, Equatable, Hashable {
    public let message: String
    public let range: Range<Int>

    public init(message: String, range: Range<Int>) {
        self.message = message
        self.range = range
    }
}

public struct PascalLexResult: Sendable, Equatable {
    public let tokens: [PascalToken]
    public let elements: [PascalLexicalElement]
    public let diagnostics: [PascalDiagnostic]

    public var reconstructedSource: String {
        elements.map(\.lexeme).joined()
    }
}

public struct PascalLexer: Sendable {
    public let languageKit: PascalLanguageKit

    public init(languageKit: PascalLanguageKit = .bundled) {
        self.languageKit = languageKit
    }

    public func tokenize(_ snapshot: SourceSnapshot) -> PascalLexResult {
        let scanner = makeScanner(languageKit)
        return project(scanner.scan(
            text: snapshot.text,
            from: .start,
            revision: snapshot.revision.rawValue,
            shouldStopBefore: nil))
    }
}

public struct PascalIncrementalLexResult: Sendable, Equatable {
    public let revision: SourceRevision
    public let lexed: PascalLexResult
    public let metrics: RestartAndConvergeMetrics

    public var evidence: IncrementalExecutionEvidence {
        .init(
            strategy: metrics.incremental ? .incremental : .full,
            measurements: [.init(
                dimension: .tokens,
                reused: metrics.reusedPrefixTokenCount + metrics.reusedSuffixTokenCount,
                rebuilt: metrics.generatedTokenCount,
                strategy: metrics.incremental
                    ? "restart-and-converge" : "full-tokenization")])
    }
}

public struct PascalIncrementalTokenizer: Sendable {
    private var tokenizer: GrammarLanguageTokenizer<PascalLexicalProjection>

    public init(languageKit: PascalLanguageKit = .bundled) {
        do {
            tokenizer = try GrammarLanguageTokenizer(
                specification: languageKit.artifact.lexicalSpecification,
                projection: PascalLexicalProjection())
        } catch {
            preconditionFailure("Invalid compiled Pascal lexical artifact: \(error)")
        }
    }

    public mutating func tokenize(
        _ snapshot: SourceSnapshot,
        change: SourceChange? = nil
    ) -> PascalIncrementalLexResult {
        let result = tokenizer.tokenize(snapshot: snapshot, change: change)
        return PascalIncrementalLexResult(
            revision: snapshot.revision,
            lexed: PascalLexResult(
                tokens: result.output.tokens,
                elements: result.output.elements,
                diagnostics: result.output.diagnostics),
            metrics: result.metrics)
    }

    public mutating func reset() { tokenizer.reset() }
}

private struct PascalLexicalProjection: GrammarLexicalProjection {
    func token(_ token: GrammarLexicalToken) -> PascalToken {
        project(token)
    }

    func element(
        _ element: GrammarLexicalElement
    ) -> PascalLexicalElement? {
        project(element)
    }

    func diagnostic(
        _ diagnostic: GrammarLexicalDiagnostic
    ) -> PascalDiagnostic {
        project(diagnostic)
    }
}

private func makeScanner(_ languageKit: PascalLanguageKit) -> GrammarDrivenLexer {
    do {
        return try GrammarDrivenLexer(
            specification: languageKit.artifact.lexicalSpecification)
    } catch {
        preconditionFailure("Invalid compiled Pascal lexical artifact: \(error)")
    }
}

private func project(
    _ scan: RestartableLexicalScan<GrammarLexicalToken,
                                  GrammarLexicalElement,
                                  GrammarLexicalDiagnostic>
) -> PascalLexResult {
    PascalLexResult(
        tokens: scan.tokens.map(project),
        elements: scan.elements.map(project),
        diagnostics: scan.diagnostics.map(project))
}

private func project(_ token: GrammarLexicalToken) -> PascalToken {
    PascalToken(
        id: token.id,
        kind: PascalTokenKind(rawValue: token.kind),
        lexeme: token.lexeme,
        range: token.range,
        line: token.position.line,
        column: token.position.column,
        isEndOfInput: token.isEndOfInput)
}

private func project(_ element: GrammarLexicalElement) -> PascalLexicalElement {
    let kind: PascalLexicalElementKind
    switch element.kind {
    case .token(let name): kind = .token(PascalTokenKind(rawValue: name))
    case .trivia(let name): kind = .trivia(name)
    case .invalid: kind = .invalid
    }
    return PascalLexicalElement(
        id: element.id,
        kind: kind,
        lexeme: element.lexeme,
        range: element.range)
}

private func project(_ diagnostic: GrammarLexicalDiagnostic) -> PascalDiagnostic {
    PascalDiagnostic(message: diagnostic.message, range: diagnostic.range)
}
