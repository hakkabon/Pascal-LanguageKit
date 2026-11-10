import IncrementalParsing
import LanguageTooling

public enum PascalSymbolKind: String, Sendable, Equatable, Codable {
    case program, constant, type, variable, procedure, function

    var toolingKind: ToolingSymbolKind {
        switch self {
        case .program: .module
        case .constant: .constant
        case .type: .type
        case .variable: .variable
        case .procedure, .function: .function
        }
    }
}

public struct PascalSymbol: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let kind: PascalSymbolKind
    public let declarationRange: SourceRange
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
    public let semanticTokens: [PascalSemanticToken]
    public let diagnostics: [PascalDiagnostic]
    public let reuseMetrics: PascalSemanticReuseMetrics

    public var toolingIndex: ToolingSemanticIndex {
        let scope = ToolingScopeID("pascal:file")
        return ToolingSemanticIndex(
            symbols: symbols.map {
                ToolingSymbol(
                    id: .init($0.id), name: $0.name,
                    kind: $0.kind.toolingKind,
                    declarationRange: $0.declarationRange,
                    scopeID: scope,
                    detail: "\($0.kind.rawValue) \($0.name)",
                    modifiers: ["declaration"])
            },
            references: references.map {
                ToolingReference(
                    symbolID: .init($0.symbolID), range: $0.range,
                    role: $0.role)
            },
            scopes: [.init(
                id: scope, parentID: nil,
                range: .init(0, Int.max),
                symbolIDs: symbols.map { .init($0.id) })])
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
        var declarations: [(Int, PascalSymbolKind)] = []
        var section: PascalSymbolKind?
        var expectSingleDeclaration = false
        var variableNames = false
        var nextNamedDeclaration: PascalSymbolKind?

        for (index, token) in significant.enumerated() {
            let kind = token.kind.rawValue
            switch kind {
            case "PROGRAM":
                nextNamedDeclaration = .program
            case "CONST":
                section = .constant; expectSingleDeclaration = true
            case "TYPE":
                section = .type; expectSingleDeclaration = true
            case "VAR":
                section = .variable; variableNames = true
            case "PROCEDURE":
                section = nil; nextNamedDeclaration = .procedure
            case "FUNCTION":
                section = nil; nextNamedDeclaration = .function
            case "BEGIN":
                section = nil
            case "COLON" where section == .variable:
                variableNames = false
            case "SEMICOLON":
                if section == .constant || section == .type {
                    expectSingleDeclaration = true
                } else if section == .variable {
                    variableNames = true
                }
            case "IDENTIFIER":
                if let named = nextNamedDeclaration {
                    declarations.append((index, named))
                    nextNamedDeclaration = nil
                } else if section == .constant || section == .type,
                          expectSingleDeclaration {
                    declarations.append((index, section!))
                    expectSingleDeclaration = false
                } else if section == .variable, variableNames {
                    declarations.append((index, .variable))
                }
            default:
                break
            }
        }

        let declarationByIndex = Dictionary(uniqueKeysWithValues: declarations)
        var symbols: [PascalSymbol] = []
        var symbolsByName: [String: PascalSymbol] = [:]
        var diagnostics: [PascalDiagnostic] = []
        for (index, kind) in declarations {
            let token = significant[index]
            let symbol = PascalSymbol(
                id: "pascal-symbol:\(token.id)", name: token.lexeme,
                kind: kind, declarationRange: token.range)
            let key = token.lexeme.lowercased()
            if symbolsByName[key] != nil {
                diagnostics.append(.init(
                    severity: .error,
                    message: "Duplicate Pascal declaration '\(token.lexeme)'.",
                    range: token.range))
            } else {
                symbolsByName[key] = symbol
            }
            symbols.append(symbol)
        }

        var references: [PascalSymbolReference] = []
        for (index, token) in significant.enumerated()
            where token.kind.rawValue == "IDENTIFIER" && declarationByIndex[index] == nil {
            guard let symbol = symbolsByName[token.lexeme.lowercased()] else { continue }
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
            symbols.first(where: { $0.id == reference.symbolID }).map {
                PascalSemanticToken(
                    range: reference.range, kind: $0.kind,
                    isDeclaration: false)
            }
        }
        let oldSymbolIDs = reusingPrevious
            ? Set(previous?.symbols.map(\.id) ?? []) : []
        let oldReferenceIDs = reusingPrevious
            ? Set(previous?.references.map(\.tokenID) ?? []) : []
        let reusedSymbols = symbols.filter { oldSymbolIDs.contains($0.id) }.count
        let reusedReferences = references.filter {
            oldReferenceIDs.contains($0.tokenID)
        }.count
        let model = PascalSemanticModel(
            revision: revision, symbols: symbols, references: references,
            semanticTokens: semanticTokens, diagnostics: diagnostics,
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
