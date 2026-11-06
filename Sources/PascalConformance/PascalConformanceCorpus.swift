/// Stable language examples shared by parser engines, editors, grammar tools,
/// and mutation campaigns. These are source fixtures, not expected parser
/// implementations, so consumers remain free to produce their native trees.
public enum PascalConformanceCorpus {
    public static let accepted: [String] = [
        ".",
        "const a = 1, b = 2; .",
        "var x, y; x := -1 + 2 * (3 + y).",
        "procedure p; call p; call p.",
        "begin call p; if odd x then x := x + 1; while x # 0 do x := x - 1 end.",
        "begin if x <= 10 then x := 1; if x >= 2 then x := 0 end.",
    ]
}
