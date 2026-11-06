import IncrementalParsing

public struct PascalProvider: LanguageProvider {
    public let descriptor = LanguageProviderDescriptor(
        id: "pascal",
        displayName: "Pascal",
        fileExtensions: ["pas", "p"],
        distribution: .externalLanguageKit,
        capabilities: [.syntaxHighlighting, .incrementalAnalysis, .diagnostics])

    public init() {}

    public func makeSession() -> any LanguageProviderSession {
        PascalProviderSession()
    }
}

public actor PascalProviderSession: LanguageProviderSession {
    private let languageKit: PascalLanguageKit
    private let session: PascalLanguageSession

    public init(languageKit: PascalLanguageKit = .bundled) {
        self.languageKit = languageKit
        session = PascalLanguageSession(languageKit: languageKit)
    }

    public func analyze(
        _ snapshot: SourceSnapshot,
        change: SourceChange?
    ) async throws -> LanguageProviderAnalysis {
        let analysis = try await session.analyze(snapshot, change: change)
        return LanguageProviderAnalysis(
            languageID: "pascal",
            revision: snapshot.revision,
            artifact: languageKit.artifact.incrementalIdentity,
            tokens: providerTokens(analysis.lexing.lexed.elements),
            diagnostics: analysis.parsing.diagnostics.map {
                LanguageProviderDiagnostic(
                    severity: .error,
                    message: $0.message,
                    range: .init($0.range))
            },
            operations: [
                .init(operation: "lexing", evidence: analysis.lexing.evidence),
                .init(operation: "parsing", evidence: analysis.parsing.metrics.evidence),
            ])
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
}

private extension IncrementalParsing.SourceRange {
    init(_ range: Range<Int>) {
        self.init(range.lowerBound, range.upperBound)
    }
}
