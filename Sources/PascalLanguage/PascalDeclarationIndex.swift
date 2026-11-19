import IncrementalParsing
import LanguageTooling

/// Projects Pascal declaration boundaries from the grammar-derived tokens.
/// Earley remains responsible for syntax acceptance and recovery. This walk is
/// deliberately tolerant of incomplete headings and blocks during editing.
struct PascalDeclarationIndex {
    private struct Scope {
        let id: ToolingScopeID
        let parent: ToolingScopeID?
        let start: Int
        var end: Int
    }

    private let tokens: [PascalToken]
    private var cursor = 0
    private var scopeRecords: [Scope] = [
        .init(id: .init("pascal:file"), parent: nil, start: 0, end: Int.max)
    ]
    private(set) var symbols: [PascalSymbol] = []
    private(set) var excludedReferences: Set<Int> = []
    private(set) var diagnostics: [PascalDiagnostic] = []
    private var declaredNames: [ToolingScopeID: Set<String>] = [:]

    var scopes: [ToolingScope] {
        scopeRecords.map { scope in
            .init(id: scope.id, parentID: scope.parent,
                  range: .init(scope.start, scope.end),
                  symbolIDs: symbols.filter { $0.scopeID == scope.id }.map { .init($0.id) })
        }
    }

    init(tokens: [PascalToken]) {
        self.tokens = tokens
        if kind == "PROGRAM" {
            cursor += 1
            declare(.program, in: 0)
            // Program file parameters are outside this semantic slice.
            skipDeclaration()
        }
        _ = block(in: 0)
    }

    private var kind: String {
        cursor < tokens.count ? tokens[cursor].kind.rawValue : ""
    }

    private mutating func declare(_ kind: PascalSymbolKind, in scope: Int) {
        guard self.kind == "IDENTIFIER" else { return }
        let token = tokens[cursor]
        let scopeID = scopeRecords[scope].id
        if !declaredNames[scopeID, default: []].insert(token.lexeme.lowercased()).inserted {
            diagnostics.append(.init(
                severity: .error,
                message: "Duplicate Pascal declaration '\(token.lexeme)'.",
                range: token.range))
        }
        symbols.append(.init(
            id: "pascal-symbol:\(token.id)", name: token.lexeme, kind: kind,
            declarationRange: token.range, scopeID: scopeID))
        excludedReferences.insert(cursor)
        cursor += 1
    }

    private mutating func block(in scope: Int) -> Bool {
        while cursor < tokens.count {
            switch kind {
            case "CONST", "TYPE", "VAR":
                let section = kind
                cursor += 1
                while kind == "IDENTIFIER" {
                    let symbolKind: PascalSymbolKind = section == "CONST" ? .constant
                        : section == "TYPE" ? .type : .variable
                    declare(symbolKind, in: scope)
                    if section == "VAR" {
                        while kind == "COMMA" {
                            cursor += 1
                            guard kind == "IDENTIFIER" else { break }
                            declare(.variable, in: scope)
                        }
                    }
                    skipDeclaration()
                }
            case "PROCEDURE", "FUNCTION": routine(in: scope)
            case "BEGIN":
                return skipBody()
            case "END", "PERIOD": return false
            default: cursor += 1
            }
        }
        return false
    }

    private mutating func routine(in parent: Int) {
        let routineKind: PascalSymbolKind = kind == "FUNCTION" ? .function : .procedure
        cursor += 1
        guard kind == "IDENTIFIER" else { return }
        let name = tokens[cursor]
        declare(routineKind, in: parent)
        let scope = scopeRecords.count
        scopeRecords.append(.init(
            id: .init("pascal:scope:\(name.id)"), parent: scopeRecords[parent].id,
            start: name.range.upperBound, end: Int.max))
        if kind == "LEFT_PAREN" { parameters(in: scope) }
        // Includes the return type of a function, whose identifiers remain references.
        skipDeclaration()
        let complete = block(in: scope)
        if complete && cursor > 0 {
            scopeRecords[scope].end = tokens[cursor - 1].range.upperBound
        }
        if kind == "SEMICOLON" { cursor += 1 }
    }

    private mutating func parameters(in scope: Int) {
        cursor += 1
        while cursor < tokens.count && kind != "RIGHT_PAREN" {
            let start = cursor
            if kind == "VAR" { cursor += 1 }
            if kind == "PROCEDURE" || kind == "FUNCTION" {
                cursor += 1
                declare(.parameter, in: scope)
                // Higher-order signature bindings are not projected yet. Avoid
                // binding signature-local names to unrelated surrounding symbols.
                skipParameterSignature()
            } else {
                declare(.parameter, in: scope)
                while kind == "COMMA" {
                    cursor += 1
                    guard kind == "IDENTIFIER" else { break }
                    declare(.parameter, in: scope)
                }
                while cursor < tokens.count && kind != "SEMICOLON" && kind != "RIGHT_PAREN" {
                    // A missing ')' should not swallow the following routine body.
                    if kind == "BEGIN" || kind == "END" { return }
                    cursor += 1
                }
            }
            if kind == "SEMICOLON" { cursor += 1 }
            if cursor == start { cursor += 1 }
        }
        if kind == "RIGHT_PAREN" { cursor += 1 }
    }

    private mutating func skipParameterSignature() {
        var depth = 0
        while cursor < tokens.count {
            if depth == 0 && (kind == "SEMICOLON" || kind == "RIGHT_PAREN") { return }
            if kind == "BEGIN" || kind == "END" { return }
            if kind == "LEFT_PAREN" { depth += 1 }
            if kind == "RIGHT_PAREN" { depth -= 1 }
            excludedReferences.insert(cursor)
            cursor += 1
        }
    }

    private mutating func skipDeclaration() {
        var records = 0
        var parentheses = 0
        while cursor < tokens.count {
            if records == 0 && parentheses == 0 {
                if kind == "SEMICOLON" { cursor += 1; return }
                if ["BEGIN", "CONST", "TYPE", "VAR", "PROCEDURE", "FUNCTION", "END", "PERIOD"].contains(kind) {
                    return
                }
            }
            if kind == "RECORD" { records += 1 }
            if kind == "END" && records > 0 { records -= 1 }
            // Record fields and enumeration members need their own semantic model.
            // Do not accidentally resolve their declaration names as local references.
            if records > 0 || parentheses > 0 { excludedReferences.insert(cursor) }
            if kind == "LEFT_PAREN" { parentheses += 1 }
            if kind == "RIGHT_PAREN" { parentheses = max(0, parentheses - 1) }
            cursor += 1
        }
    }

    private mutating func skipBody() -> Bool {
        var depth = 0
        while cursor < tokens.count {
            if kind == "BEGIN" || kind == "CASE" { depth += 1 }
            if kind == "END" {
                depth -= 1
                cursor += 1
                if depth == 0 { return true }
            } else {
                cursor += 1
            }
        }
        return false
    }
}
