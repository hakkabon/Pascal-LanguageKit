import IncrementalParsing
import LanguageTooling

public enum PascalSymbolKind: String, Sendable, Equatable, Codable {
    case program, constant, type, variable, parameter, procedure, function

    var toolingKind: ToolingSymbolKind {
        switch self {
        case .program: .module
        case .constant: .constant
        case .type: .type
        case .variable: .variable
        case .parameter: .parameter
        case .procedure, .function: .function
        }
    }
}

public struct PascalSymbol: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let kind: PascalSymbolKind
    public let declarationRange: SourceRange
    public let scopeID: ToolingScopeID
}

public struct PascalSymbolReference: Sendable, Hashable, Identifiable {
    public let tokenID: String
    public let symbolID: String
    public let range: SourceRange
    public let role: ToolingReferenceRole
    public var id: String { tokenID }
}

public struct PascalSemanticToken: Sendable, Equatable, Identifiable {
    public let range: SourceRange
    public let kind: PascalSymbolKind
    public let isDeclaration: Bool
    public var id: String {
        "\(range.location):\(range.length):\(kind.rawValue):\(isDeclaration)"
    }
}

public struct PascalSemanticReuseMetrics: Sendable, Equatable {
    public let incremental: Bool
    public let reusedSymbolCount: Int
    public let rebuiltSymbolCount: Int
    public let reusedReferenceCount: Int
    public let rebuiltReferenceCount: Int

    public var evidence: IncrementalExecutionEvidence {
        .init(
            strategy: incremental ? .incremental : .full,
            measurements: [.init(
                dimension: .semanticNodes,
                reused: reusedSymbolCount + reusedReferenceCount,
                rebuilt: rebuiltSymbolCount + rebuiltReferenceCount,
                strategy: incremental
                    ? "stable-pascal-binding-index" : "full-pascal-binding-index")])
    }
}

public struct PascalSemanticModel: Sendable, Equatable {
    public let revision: SourceRevision
    public let symbols: [PascalSymbol]
    public let references: [PascalSymbolReference]
    public let scopes: [ToolingScope]
    public let semanticTokens: [PascalSemanticToken]
    public let diagnostics: [PascalDiagnostic]
    public let reuseMetrics: PascalSemanticReuseMetrics

    public var toolingIndex: ToolingSemanticIndex {
        ToolingSemanticIndex(
            symbols: symbols.map {
                ToolingSymbol(
                    id: .init($0.id), name: $0.name,
                    kind: $0.kind.toolingKind,
                    declarationRange: $0.declarationRange,
                    scopeID: $0.scopeID,
                    detail: "\($0.kind.rawValue) \($0.name)",
                    modifiers: ["declaration"])
            },
            references: references.map {
                ToolingReference(
                    symbolID: .init($0.symbolID), range: $0.range,
                    role: $0.role)
            },
            scopes: scopes)
    }
}

struct PascalIncrementalSemanticAnalyzer {
    private var previous: PascalSemanticModel?

    mutating func analyze(
        revision: SourceRevision,
        tokens: [PascalToken],
        reusingPrevious: Bool
    ) -> PascalSemanticModel {
        let significant = tokens.filter { !$0.isEndOfInput }
        let declarations = PascalDeclarationIndex(tokens: significant)
        let symbols = declarations.symbols
        let symbolsByID = Dictionary(uniqueKeysWithValues: symbols.map { ($0.id, $0) })
        let lookup = ToolingSemanticIndex(
            symbols: symbols.map {
                .init(id: .init($0.id), name: $0.name, kind: $0.kind.toolingKind,
                      declarationRange: $0.declarationRange, scopeID: $0.scopeID)
            }, references: [], scopes: declarations.scopes)

        var references: [PascalSymbolReference] = []
        for (index, token) in significant.enumerated()
            where token.kind.rawValue == "IDENTIFIER" && !declarations.excludedReferences.contains(index) {
            // A field selector is not a reference to an equally named local variable.
            if index > 0 && significant[index - 1].kind.rawValue == "PERIOD" { continue }
            guard let visible = lookup.visibleSymbols(at: token.range.location).first(where: {
                $0.name.lowercased() == token.lexeme.lowercased()
            }), let symbol = symbolsByID[visible.id.rawValue] else { continue }
            let previousKind = index > 0 ? significant[index - 1].kind.rawValue : ""
            let nextKind = index + 1 < significant.count
                ? significant[index + 1].kind.rawValue : ""
            let role: ToolingReferenceRole
            if nextKind == "ASSIGN" { role = .write }
            else if symbol.kind == .procedure || symbol.kind == .function { role = .call }
            else if previousKind == "COLON" || symbol.kind == .type { role = .type }
            else { role = .read }
            references.append(.init(
                tokenID: token.id, symbolID: symbol.id,
                range: token.range, role: role))
        }

        let semanticTokens = symbols.map {
            PascalSemanticToken(
                range: $0.declarationRange, kind: $0.kind,
                isDeclaration: true)
        } + references.compactMap { reference in
            symbolsByID[reference.symbolID].map {
                PascalSemanticToken(
                    range: reference.range, kind: $0.kind,
                    isDeclaration: false)
            }
        }
        let oldSymbols = Dictionary(uniqueKeysWithValues:
            (reusingPrevious ? previous?.symbols ?? [] : []).map { ($0.id, $0) })
        let oldReferences = Dictionary(uniqueKeysWithValues:
            (reusingPrevious ? previous?.references ?? [] : []).map { ($0.tokenID, $0) })
        let reusedSymbols = symbols.filter {
            guard let old = oldSymbols[$0.id] else { return false }
            return old.name == $0.name && old.kind == $0.kind && old.scopeID == $0.scopeID
        }.count
        let reusedReferences = references.filter {
            guard let old = oldReferences[$0.tokenID] else { return false }
            return old.symbolID == $0.symbolID && old.role == $0.role
        }.count
        let model = PascalSemanticModel(
            revision: revision, symbols: symbols, references: references,
            scopes: declarations.scopes,
            semanticTokens: semanticTokens, diagnostics: declarations.diagnostics,
            reuseMetrics: .init(
                incremental: reusingPrevious && previous != nil,
                reusedSymbolCount: reusedSymbols,
                rebuiltSymbolCount: symbols.count - reusedSymbols,
                reusedReferenceCount: reusedReferences,
                rebuiltReferenceCount: references.count - reusedReferences))
        previous = model
        return model
    }

    mutating func reset() { previous = nil }
}
