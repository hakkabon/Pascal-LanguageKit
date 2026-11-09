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

The provider adopts `Language-Tooling` directly. Its first semantic trial
indexes program, constant, type, variable, procedure, and function declarations
from the stable grammar-derived token stream. The shared tooling index now
drives symbol-aware completion, definition, references, hover, and semantic
tokens, while stable lexer identities publish incremental binding reuse.

## Products

- `PascalLanguage`: compiled artifact, lossless lexer, incremental tokenizer,
  generalized parser, document session and unified language provider.
- `PascalConformance`: accepted, rejected and mutation fixtures.
- `PascalFrontendConformance`: portable observation reports and the Phase 19
  product campaign.

## Current limitations

- Accepted edits resume Earley-Parser's native live chart using stable Pascal
  token identities. Diagnostic and generalized-recovery searches deliberately
  use a clean fallback when the live recognizer cannot accept the input.
- Syntax recovery performs a deterministic, bounded minimum-edit search through
  the shared `Parser` facility. Successful repairs are reparsed by Earley and
  therefore retain a real BSR/SPPF plus portable insert/delete evidence. The
  trial does not yet project that forest into a Pascal-specific typed CST.
- The semantic trial currently models one file-level scope. Formal parameters,
  record fields, nested procedure scopes, type checking, formatting,
  compilation, execution, and rename UI remain future Pascal-owned work.
- The grammar is a practical core and still requires conformance work before it
  can claim a specific Pascal standard.

Run the validation suite with:

```sh
swift test
```
