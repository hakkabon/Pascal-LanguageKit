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

The provider adopts `Language-Tooling` directly. Its semantic trial indexes
program, constant, type, variable, parameter, procedure, and function declarations from the stable grammar-derived token
stream. Routine scopes support nested declarations, outer-name capture,
case-insensitive shadowing, and scope-local duplicate diagnostics. The shared
tooling index now drives symbol-aware completion, definition, references, hover, and semantic
tokens, while stable lexer identities publish incremental binding reuse.
Its tokens, source ranges, diagnostics, and recovery projection now use the
canonical Incremental-Parsing and Parser contracts; the kit does not define a
second consumer-facing diagnostic or range model.

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
- The semantic projection supports file and nested routine scopes with value
  and `var` parameters. Record fields, enumeration members, bindings inside
  higher-order parameter signatures, predefined environments, declaration-order
  validation, type checking, formatting, compilation, execution, and rename UI
  remain future Pascal-owned work. Unresolved names are not diagnosed yet.
- The grammar is a practical core and still requires conformance work before it
  can claim a specific Pascal standard.

Run the validation suite with:

```sh
swift test
```

## Scoped tooling trial

`PascalConformanceCorpus.scopedTooling` is an accepted program with a global
`count`, an `Outer(value)` procedure that declares its own `count`, a nested
`Inner(delta)` procedure that captures the local `count`, and a sibling
procedure that uses the global `count`. It is included in the common corpus
and the v4 product campaign.

Use `PascalProviderSession` to analyze the example, then request completion,
definition, references, hover, or semantic tokens through the same
`LanguageToolingSession` interface used by other kits. Inside `Inner`, both
parameters and the local `count` are visible. At the main program body, routine
locals and parameters are absent from completion.

The semantic walk projects declaration boundaries from grammar-derived tokens;
syntax recognition, repair search, and native chart reuse stay in Earley. It
also tolerates incomplete routine bodies and a missing heading semicolon.
Queries and shadowing use the shared `ToolingSemanticIndex`. No editor or
parser infrastructure is introduced into the kit.

The binding model is recomputed on each analysis. Reuse metrics describe retained
symbol and binding identities, not avoided semantic computation. An unchanged
reference whose declaration or role changes is counted as rebuilt. Tests compare
edited bindings and semantic tokens with fresh analysis, including shadowing
edits and UTF-16 range relocation.

Run only the new tooling checks with `swift test --filter PascalScopeTests`, or
run `swift test` for the conformance corpus and measured campaign as well.
