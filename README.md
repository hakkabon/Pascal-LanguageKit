# Pascal LanguageKit

An external language kit used to validate the Incremental Parsing platform with
a language developed independently of PL/0.

The current grammar is a compact but substantial Pascal core. It includes
constants and types, arrays, records, sets, files and pointers, variables,
procedures and functions, structured statements, designators, sets and
expressions. It is intentionally not presented as complete ISO 7185 Pascal.

## Single-source pipeline

`Sources/PascalLanguage/Resources/Pascal.grammar` is compiled by `GrammarParser`.
Its ordered `LexicalSpecification` is executed by `GrammarDrivenLexer`, and the
lowered productions are consumed by the ecosystem Earley parser. The kit does
not contain another grammar reader, scanner, regular-expression table, or
restart-and-converge implementation.

Pascal keywords use the shared readable form:

```text
keyword PROGRAM = insensitive("program");
token IDENTIFIER = /[A-Za-z_][A-Za-z0-9_]*/;
symbol ASSIGN = ":=";
trivia BRACE_COMMENT = blockComment("{", "}");
```

The artifact validates its start symbol, every production terminal, duplicate
rules, and unused significant lexical rules during package initialization.

## Products

- `PascalLanguage`: compiled artifact, lossless lexer, incremental tokenizer,
  generalized parser, document session and unified language provider.
- `PascalConformance`: accepted, rejected and mutation fixtures.
- `PascalFrontendConformance`: portable observation reports and the Phase 19
  product campaign.

## Current limitations

- The Earley chart is rebuilt after edits. The provider reports
  `pascal.earley.fullReparse`; it never claims parser-state reuse.
- Syntax recovery currently produces a stable bounded diagnostic, but not a
  repaired Pascal CST.
- Semantic analysis, formatting, compilation and execution are outside this
  trial increment.
- The grammar is a practical core and still requires conformance work before it
  can claim a specific Pascal standard.

Run the validation suite with:

```sh
swift test
```
