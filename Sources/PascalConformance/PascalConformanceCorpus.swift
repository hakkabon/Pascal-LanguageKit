/// Stable compact-Pascal examples shared by parser engines, editors, grammar
/// tools, and mutation campaigns. The corpus deliberately exercises mixed-case
/// reserved words because Pascal source is case-insensitive.
public enum PascalConformanceCorpus {
    public static let accepted: [String] = [
        "program Empty; begin end.",
        "PROGRAM Count(input, output); VAR x: integer; BEGIN x := 1 END.",
        "program Demo; const limit = 10; type index = 1..10; var i: index; begin for i := 1 to limit do i := i + 1 end.",
        "program Procedures; procedure hello; begin end; begin hello end.",
        "program Text; const greeting = 'Hello'; begin { retained comment } end.",
        "program Arrays; type vector = array[1..10] of integer; var v: vector; begin v[1] := 2 end.",
    ]

    public static let rejected: [String] = [
        "program MissingSemicolon begin end.",
        "program MissingEnd; begin",
        "program MissingExpression; var x: integer; begin x := end.",
        "program InvalidCharacter; begin @ end.",
    ]

    public static let mutationSeeds: [String] = [
        accepted[1],
        accepted[2],
        accepted[5],
    ]
}
