import Foundation
import Grammar
import IncrementalParsing

public enum PascalLanguageKitError: Error, Sendable, Equatable, CustomStringConvertible {
    case resourceMissing
    case malformedGrammar([String])
    case duplicateOrMissingStart(String)
    case unknownTerminal(production: String, terminal: String)
    case unusedSignificantTokens([String])
    case artifactMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .resourceMissing:
            "The bundled Pascal.grammar resource is missing."
        case .malformedGrammar(let diagnostics):
            "Malformed Pascal grammar: \(diagnostics.joined(separator: "; "))"
        case .duplicateOrMissingStart(let name):
            "The start symbol '\(name)' is missing or ambiguous."
        case .unknownTerminal(let production, let terminal):
            "Production \(production) refers to unknown terminal \(terminal)."
        case .unusedSignificantTokens(let names):
            "Pascal lexical rules are not referenced by the grammar: \(names.joined(separator: ", "))."
        case .artifactMismatch(let expected, let actual):
            "Grammar artifact mismatch: expected \(expected), received \(actual)."
        }
    }
}

public enum PascalTokenRole: String, Codable, Hashable, Sendable {
    case keyword
    case symbol
    case token
    case trivia
}

public struct PascalTokenDefinition: Codable, Hashable, Sendable, Identifiable {
    public let name: String
    public let role: PascalTokenRole
    public let matcher: LexicalMatcher
    public var id: String { name }
}

public enum PascalGrammarSymbolDefinition: Codable, Hashable, Sendable {
    case terminal(String)
    case nonterminal(String)
}

public struct PascalProductionDefinition: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let lhs: String
    public let rhs: [PascalGrammarSymbolDefinition]
}

public struct PascalGrammarArtifact: Sendable, Equatable {
    public let artifactID: String
    public let revision: UInt64
    public let source: String
    public let fingerprint: String
    public let startSymbol: String
    public let tokenDefinitions: [PascalTokenDefinition]
    public let productions: [PascalProductionDefinition]
    public let lexicalSpecification: LexicalSpecification

    public var incrementalIdentity: IncrementalArtifactIdentity {
        .init(id: artifactID, revision: revision, fingerprint: fingerprint)
    }

    public func definition(named name: String) -> PascalTokenDefinition? {
        tokenDefinitions.first { $0.name == name }
    }
}

/// A compiled, immutable Pascal definition. The grammar resource is the sole
/// source of lexical rules and parser productions; typed clients project its
/// stable rule names instead of restating the scanner.
public struct PascalLanguageKit: Sendable, Equatable {
    public static let artifactID = "org.hakkabon.languagekit.pascal"

    public static let bundled: PascalLanguageKit = {
        do { return try loadBundled() }
        catch { preconditionFailure("Invalid bundled Pascal language kit: \(error)") }
    }()

    public let artifact: PascalGrammarArtifact

    public static func loadBundled() throws -> PascalLanguageKit {
        guard let url = Bundle.module.url(forResource: "Pascal", withExtension: "grammar") else {
            throw PascalLanguageKitError.resourceMissing
        }
        return try compile(source: String(contentsOf: url, encoding: .utf8))
    }

    public static func compile(
        source: String,
        revision: UInt64 = 1,
        artifactID: String = artifactID
    ) throws -> PascalLanguageKit {
        let parser = GrammarParser(grammar: source)
        let syntax = parser.parse()
        guard parser.diagnostics.isEmpty else {
            throw PascalLanguageKitError.malformedGrammar(
                parser.diagnostics.map(\.description))
        }

        let converted = StandardNotation().rewriteToStandardNotation(syntax: syntax)
        let specification = parser.lexicalSpecification
        let start = converted.start
        let goals = Set(converted.0.map { $0.goal.name })
        guard !start.isEmpty, goals.contains(start) else {
            throw PascalLanguageKitError.duplicateOrMissingStart(start)
        }

        let significantNames = Set(specification.significantRules.map(\.name))
        var referencedNames = Set<String>()
        let productions = try converted.0.enumerated().map { ordinal, production in
            let rhs = try production.rule.map { symbol -> PascalGrammarSymbolDefinition in
                switch symbol {
                case .nonTerminal(let value):
                    return .nonterminal(value.name)
                case .terminal(let terminal):
                    guard let name = converted.lexical.first(where: {
                        significantNames.contains($0.key) && $0.value == terminal
                    })?.key else {
                        throw PascalLanguageKitError.unknownTerminal(
                            production: production.goal.name,
                            terminal: terminal.description)
                    }
                    referencedNames.insert(name)
                    return .terminal(name)
                case .metaSymbol(let value):
                    throw PascalLanguageKitError.unknownTerminal(
                        production: production.goal.name,
                        terminal: value.rawValue)
                }
            }
            return PascalProductionDefinition(
                id: "p\(ordinal):\(production.goal.name)",
                lhs: production.goal.name,
                rhs: rhs)
        }

        let unused = significantNames.subtracting(referencedNames).sorted()
        guard unused.isEmpty else {
            throw PascalLanguageKitError.unusedSignificantTokens(unused)
        }

        let definitions = specification.rules.map { rule in
            PascalTokenDefinition(
                name: rule.name,
                role: role(for: rule),
                matcher: rule.matcher)
        }
        return PascalLanguageKit(artifact: PascalGrammarArtifact(
            artifactID: artifactID,
            revision: revision,
            source: source,
            fingerprint: stableFingerprint(source),
            startSymbol: start,
            tokenDefinitions: definitions,
            productions: productions,
            lexicalSpecification: specification))
    }

    public func requireArtifact(_ identity: IncrementalArtifactIdentity) throws {
        guard identity.id == artifact.artifactID,
              identity.revision == artifact.revision,
              identity.fingerprint == artifact.fingerprint else {
            throw PascalLanguageKitError.artifactMismatch(
                expected: "\(artifact.artifactID)@\(artifact.revision):\(artifact.fingerprint)",
                actual: "\(identity.id)@\(identity.revision):\(identity.fingerprint)")
        }
    }
}

private func role(for rule: LexicalRuleDefinition) -> PascalTokenRole {
    guard rule.channel == .significant else { return .trivia }
    switch rule.matcher {
    case .caseInsensitiveLiteral: return .keyword
    case .literal, .literals, .characterRange: return .symbol
    case .regularExpression: return .token
    case .lineComment, .blockComment: return .trivia
    }
}

private func stableFingerprint(_ source: String) -> String {
    var value: UInt64 = 14_695_981_039_346_656_037
    for byte in source.utf8 {
        value ^= UInt64(byte)
        value &*= 1_099_511_628_211
    }
    return String(format: "%016llx", value)
}
