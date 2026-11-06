import Foundation
import Grammar
//import LanguageExperimentProtocol

public enum PascalLanguageKitError: Error, Sendable, Equatable, CustomStringConvertible {
    case resourceMissing
    case malformedDirective(line: Int, text: String)
    case malformedProduction(String)
    case duplicateToken(String)
    case duplicateOrMissingStart(String)
    case unknownSymbol(production: String, symbol: String)
    case unsupportedToken(String)
    case typedBindingMismatch(missing: [String], unexpected: [String])
    case artifactMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .resourceMissing: "The bundled Pascal.grammar resource is missing."
        case let .malformedDirective(line, text): "Malformed grammar directive at line \(line): \(text)"
        case let .malformedProduction(text): "Malformed grammar production: \(text)"
        case let .duplicateToken(name): "Duplicate grammar token \(name)."
        case let .duplicateOrMissingStart(name): "The start symbol '\(name)' is missing or ambiguous."
        case let .unknownSymbol(production, symbol): "Production \(production) refers to unknown symbol \(symbol)."
        case let .unsupportedToken(name): "Token \(name) has no typed Pascal binding."
        case let .typedBindingMismatch(missing, unexpected):
            "Pascal typed grammar bindings differ (missing: \(missing), unexpected: \(unexpected))."
        case let .artifactMismatch(expected, actual):
            "Grammar artifact mismatch: expected \(expected), received \(actual)."
        }
    }
}

/// A compiled, immutable PL/0 language definition. The bundled grammar is the
/// single source used for token classification, generated parser productions,
/// Workbench interchange, and experiment identity.
public struct PascalLanguageKit: Sendable, Equatable {
    public static let artifactID = "org.hakkabon.modedit.pascal"
    
    public static let bundled: PascalLanguageKit = {
        do { return try loadBundled() }
        catch { preconditionFailure("Invalid bundled Pascal language kit: \(error)") }
    }()
    
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
        return PascalLanguageKit()
    }
}
