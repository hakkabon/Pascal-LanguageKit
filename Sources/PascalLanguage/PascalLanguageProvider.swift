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
            .semantics,
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
    private let documentURI: String

    public init(languageKit: PascalLanguageKit = .bundled,
                documentURI: String = "language-document://pascal") {
        self.languageKit = languageKit
        session = PascalLanguageSession(languageKit: languageKit)
        self.documentURI = documentURI
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
            tokens: providerTokens(
                analysis.lexing.lexed.elements,
                semantics: analysis.semantics),
            diagnostics: analysis.parsing.diagnostics.map {
                LanguageProviderDiagnostic(
                    severity: analysis.parsing.recovered ? .warning : .error,
                    message: $0.message,
                    range: $0.range)
            } + analysis.semantics.diagnostics.map {
                LanguageProviderDiagnostic(
                    severity: .error, message: $0.message,
                    range: $0.range)
            },
            recoveryEdits: analysis.parsing.recoveryEdits.map { edit in
                switch edit {
                case .insert(let terminal, let index):
                    let offset = analysis.lexing.lexed.tokens.indices.contains(index)
                        ? analysis.lexing.lexed.tokens[index].range.location
                        : snapshot.utf16Count
                    return .init(action: .insert(
                        terminal: terminal, atUTF16Offset: offset))
                case .delete(let terminal, let index):
                    let range = analysis.lexing.lexed.tokens.indices.contains(index)
                        ? analysis.lexing.lexed.tokens[index].range
                        : SourceRange(location: snapshot.utf16Count, length: 0)
                    return .init(action: .delete(
                        terminal: terminal, range: range))
                }
            },
            operations: [
                .init(operation: "lexing", evidence: analysis.lexing.evidence),
                .init(operation: "parsing", evidence: analysis.parsing.metrics.evidence),
                .init(operation: "semantics", evidence: analysis.semantics.reuseMetrics.evidence),
            ])
    }

    public func completions(
        at position: ToolingPosition
    ) async throws -> [ToolingCompletionItem] {
        guard let currentText else { throw LanguageToolingError.documentNotAnalyzed }
        guard SourceLineMap(currentText).offset(of: position) != nil else {
            throw LanguageToolingError.invalidPosition(position)
        }
        let keywords = languageKit.artifact.tokenDefinitions
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
        let (_, analysis, offset) = try toolingContext(at: position)
        let symbols = analysis.semantics.toolingIndex.visibleSymbols(at: offset).map {
            ToolingCompletionItem(
                label: $0.name, kind: completionKind($0.kind),
                detail: $0.detail ?? $0.kind.rawValue,
                insertText: $0.name)
        }
        return (keywords + symbols).toolingUniquedByID().sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    public func definition(at position: ToolingPosition) async throws
        -> ToolingLocation? {
        let (text, analysis, offset) = try toolingContext(at: position)
        guard let symbol = analysis.semantics.toolingIndex.symbol(at: offset) else {
            return nil
        }
        return .init(
            uri: documentURI,
            range: SourceLineMap(text).toolingRange(symbol.declarationRange))
    }

    public func hover(at position: ToolingPosition) async throws -> ToolingHover? {
        let (text, analysis, offset) = try toolingContext(at: position)
        guard let symbol = analysis.semantics.toolingIndex.symbol(at: offset) else {
            return nil
        }
        return .init(
            contents: symbol.detail ?? "\(symbol.kind.rawValue) \(symbol.name)",
            range: SourceLineMap(text).toolingRange(symbol.declarationRange))
    }

    public func references(at position: ToolingPosition) async throws
        -> [ToolingLocation] {
        let (text, analysis, offset) = try toolingContext(at: position)
        let index = analysis.semantics.toolingIndex
        guard let symbol = index.symbol(at: offset) else { return [] }
        let map = SourceLineMap(text)
        return index.references(to: symbol.id).map {
            .init(uri: documentURI, range: map.toolingRange($0))
        }
    }

    public func semanticTokens() async throws -> ToolingSemanticTokensResult {
        guard let currentText, let currentAnalysis else {
            throw LanguageToolingError.documentNotAnalyzed
        }
        let map = SourceLineMap(currentText)
        let tokens = currentAnalysis.lexing.lexed.elements.compactMap { element in
            semanticToken(element, semantics: currentAnalysis.semantics).map {
                ToolingSemanticToken(
                    range: map.toolingRange(.init(
                        element.range.lowerBound,
                        element.range.upperBound)),
                    type: $0.type,
                    isDeclaration: $0.isDeclaration)
            }
        }
        return SemanticTokenEncoder.encode(
            tokens,
            resultID: "pascal:\(currentAnalysis.revision.rawValue)")
    }

    private func providerTokens(
        _ elements: [PascalLexicalElement],
        semantics: PascalSemanticModel
    ) -> [LanguageProviderToken] {
        let semanticByRange = Dictionary(uniqueKeysWithValues:
            semantics.semanticTokens.map { ($0.range, $0) })
        return elements.compactMap { element -> LanguageProviderToken? in
            let classification: String
            switch element.kind {
            case .invalid:
                classification = "invalid"
            case .trivia(let name):
                guard name != "WHITESPACE" else { return nil }
                classification = "comment"
            case .token(let kind):
                let range = element.range
                if let semantic = semanticByRange[range] {
                    return LanguageProviderToken(
                        range: range,
                        classification: semantic.kind.toolingKind.rawValue,
                        modifiers: semantic.isDeclaration ? ["declaration"] : [])
                }
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
                range: element.range,
                classification: classification)
        }
    }

    private func semanticToken(
        _ element: PascalLexicalElement,
        semantics: PascalSemanticModel
    ) -> (type: ToolingSemanticTokenType, isDeclaration: Bool)? {
        if let semantic = semantics.semanticTokens.first(where: {
            $0.range.lowerBound == element.range.lowerBound
                && $0.range.upperBound == element.range.upperBound
        }) {
            return (semanticTokenType(semantic.kind), semantic.isDeclaration)
        }
        switch element.kind {
        case .invalid:
            return nil
        case .trivia(let name):
            return name == "WHITESPACE" ? nil : (.comment, false)
        case .token(let kind):
            guard let definition = languageKit.artifact.definition(
                named: kind.rawValue) else { return nil }
            switch definition.role {
            case .keyword: return (.keyword, false)
            case .symbol: return (.operatorToken, false)
            case .trivia: return (.comment, false)
            case .token:
                switch kind.rawValue {
                case "IDENTIFIER": return (.variable, false)
                case "STRING_LITERAL": return (.string, false)
                case "UNSIGNED_INTEGER", "UNSIGNED_REAL": return (.number, false)
                default: return nil
                }
            }
        }
    }

    private func toolingContext(at position: ToolingPosition) throws
        -> (String, PascalAnalysis, Int) {
        guard let text = currentText, let analysis = currentAnalysis else {
            throw LanguageToolingError.documentNotAnalyzed
        }
        guard let offset = SourceLineMap(text).offset(of: position) else {
            throw LanguageToolingError.invalidPosition(position)
        }
        return (text, analysis, offset)
    }

    private func semanticTokenType(_ kind: PascalSymbolKind)
        -> ToolingSemanticTokenType {
        switch kind {
        case .program: .module
        case .constant: .constant
        case .type: .type
        case .variable: .variable
        case .procedure, .function: .function
        }
    }

    private func completionKind(_ kind: ToolingSymbolKind)
        -> ToolingCompletionKind {
        switch kind {
        case .constant: .constant
        case .variable: .variable
        case .function: .function
        case .type: .type
        case .field: .field
        case .parameter: .variable
        case .module: .module
        default: .variable
        }
    }
}
