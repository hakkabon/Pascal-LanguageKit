import Grammar
import IncrementalParsing
import LanguageTooling

public struct PascalProvider: LanguageToolingProvider {
    public let descriptor = LanguageProviderDescriptor(
        id: "pascal",
        displayName: "Pascal",
        fileExtensions: ["pas", "p"],
        distribution: .externalLanguageKit,
        capabilities: [
            .syntaxHighlighting, .incrementalAnalysis, .diagnostics, .recovery,
        ])

    public init() {}

    public func makeToolingSession() -> any LanguageToolingSession {
        PascalProviderSession()
    }
}

public actor PascalProviderSession: LanguageToolingSession {
    private let languageKit: PascalLanguageKit
    private let session: PascalLanguageSession
    private var currentText: String?
    private var currentAnalysis: PascalAnalysis?

    public init(languageKit: PascalLanguageKit = .bundled) {
        self.languageKit = languageKit
        session = PascalLanguageSession(languageKit: languageKit)
    }

    public func analyze(
        _ snapshot: SourceSnapshot,
        change: SourceChange?
    ) async throws -> LanguageProviderAnalysis {
        let analysis = try await session.analyze(snapshot, change: change)
        currentText = snapshot.text
        currentAnalysis = analysis
        return LanguageProviderAnalysis(
            languageID: "pascal",
            revision: snapshot.revision,
            artifact: languageKit.artifact.incrementalIdentity,
            tokens: providerTokens(analysis.lexing.lexed.elements),
            diagnostics: analysis.parsing.diagnostics.map {
                LanguageProviderDiagnostic(
                    severity: analysis.parsing.recovered ? .warning : .error,
                    message: $0.message,
                    range: .init($0.range))
            },
            recoveryEdits: analysis.parsing.recoveryEdits.map { edit in
                switch edit {
                case .insert(let terminal, let index):
                    .insert(terminal: terminal, atToken: index)
                case .delete(let terminal, let index):
                    .delete(terminal: terminal, atToken: index)
                }
            },
            operations: [
                .init(operation: "lexing", evidence: analysis.lexing.evidence),
                .init(operation: "parsing", evidence: analysis.parsing.metrics.evidence),
            ])
    }

    public func completions(
        at position: ToolingPosition
    ) async throws -> [ToolingCompletionItem] {
        guard let currentText else { throw LanguageToolingError.documentNotAnalyzed }
        guard SourceLineMap(currentText).offset(of: position) != nil else {
            throw LanguageToolingError.invalidPosition(position)
        }
        return languageKit.artifact.tokenDefinitions
            .filter { $0.role == .keyword }
            .map {
                let spelling: String
                switch $0.matcher {
                case .literal(let value), .caseInsensitiveLiteral(let value):
                    spelling = value
                default:
                    spelling = $0.name.lowercased()
                }
                return ToolingCompletionItem(
                    label: spelling,
                    kind: .keyword,
                    detail: "Pascal keyword",
                    insertText: spelling)
            }
            .toolingUniquedByID()
            .sorted { $0.label < $1.label }
    }

    public func semanticTokens() async throws -> ToolingSemanticTokensResult {
        guard let currentText, let currentAnalysis else {
            throw LanguageToolingError.documentNotAnalyzed
        }
        let map = SourceLineMap(currentText)
        let tokens = currentAnalysis.lexing.lexed.elements.compactMap { element in
            semanticTokenType(element).map {
                ToolingSemanticToken(
                    range: map.toolingRange(.init(
                        element.range.lowerBound,
                        element.range.upperBound)),
                    type: $0)
            }
        }
        return SemanticTokenEncoder.encode(
            tokens,
            resultID: "pascal:\(currentAnalysis.revision.rawValue)")
    }

    private func providerTokens(
        _ elements: [PascalLexicalElement]
    ) -> [LanguageProviderToken] {
        elements.compactMap { element in
            let classification: String
            switch element.kind {
            case .invalid:
                classification = "invalid"
            case .trivia(let name):
                guard name != "WHITESPACE" else { return nil }
                classification = "comment"
            case .token(let kind):
                guard let definition = languageKit.artifact.definition(
                    named: kind.rawValue) else { return nil }
                switch definition.role {
                case .keyword: classification = "keyword"
                case .symbol: classification = "operator"
                case .trivia: classification = "comment"
                case .token:
                    switch kind.rawValue {
                    case "IDENTIFIER": classification = "identifier"
                    case "STRING_LITERAL": classification = "string"
                    case "UNSIGNED_INTEGER", "UNSIGNED_REAL": classification = "number"
                    default: classification = "token"
                    }
                }
            }
            return LanguageProviderToken(
                range: .init(element.range),
                classification: classification)
        }
    }

    private func semanticTokenType(
        _ element: PascalLexicalElement
    ) -> ToolingSemanticTokenType? {
        switch element.kind {
        case .invalid:
            return nil
        case .trivia(let name):
            return name == "WHITESPACE" ? nil : .comment
        case .token(let kind):
            guard let definition = languageKit.artifact.definition(
                named: kind.rawValue) else { return nil }
            switch definition.role {
            case .keyword: return .keyword
            case .symbol: return .operatorToken
            case .trivia: return .comment
            case .token:
                switch kind.rawValue {
                case "IDENTIFIER": return .variable
                case "STRING_LITERAL": return .string
                case "UNSIGNED_INTEGER", "UNSIGNED_REAL": return .number
                default: return nil
                }
            }
        }
    }
}

private extension IncrementalParsing.SourceRange {
    init(_ range: Range<Int>) {
        self.init(range.lowerBound, range.upperBound)
    }
}
