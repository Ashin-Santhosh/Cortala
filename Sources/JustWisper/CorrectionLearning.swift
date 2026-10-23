import Foundation

struct CorrectionSuggestion: Identifiable, Equatable {
    var id: String { phrase.lowercased() + "\u{0}" + replacement }
    var phrase: String
    var replacement: String
}

enum CorrectionLearning {
    /// Bounded word alignment from the text the user actually edited, never inferred from passive observation.
    static func suggestions(original: String, edited: String, recognized: String) -> [CorrectionSuggestion] {
        let pattern = "[\\p{L}\\p{N}]+(?:['’_-][\\p{L}\\p{N}]+)*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        func words(_ source: String) -> [String] {
            regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { Range($0.range, in: source).map { String(source[$0]) } }
        }
        let a = words(original), b = words(edited)
        guard !a.isEmpty, !b.isEmpty, a.count <= 500, b.count <= 500 else { return [] }
        var cost = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { cost[i][0] = i }
        for j in 0...b.count { cost[0][j] = j }
        for i in 1...a.count { for j in 1...b.count {
            cost[i][j] = min(cost[i - 1][j] + 1, cost[i][j - 1] + 1, cost[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
        } }
        enum Edit { case same; case replace(String?, String?) }
        var edits: [Edit] = [], i = a.count, j = b.count
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && a[i - 1] == b[j - 1] { edits.append(.same); i -= 1; j -= 1 }
            else if i > 0 && j > 0 && cost[i][j] == cost[i - 1][j - 1] + 1 { edits.append(.replace(a[i - 1], b[j - 1])); i -= 1; j -= 1 }
            else if i > 0 && cost[i][j] == cost[i - 1][j] + 1 { edits.append(.replace(a[i - 1], nil)); i -= 1 }
            else { edits.append(.replace(nil, b[j - 1])); j -= 1 }
        }
        var output: [CorrectionSuggestion] = [], before: [String] = [], after: [String] = []
        func flush() {
            defer { before = []; after = [] }
            guard !before.isEmpty, !after.isEmpty, before.count <= 6, after.count <= 6 else { return }
            let phrase = before.joined(separator: " "), replacement = after.joined(separator: " ")
            guard phrase != replacement, phrase.count <= 150, replacement.count <= 150 else { return }
            let probe = VocabularyEntry(phrase: phrase, replacement: "\u{0}CORRECTION\u{0}")
            guard TextProcessing.replaceVocabulary(recognized, entries: [probe]) != recognized else { return }
            let suggestion = CorrectionSuggestion(phrase: phrase, replacement: replacement)
            if !output.contains(suggestion) { output.append(suggestion) }
        }
        for edit in edits.reversed() {
            switch edit { case .same: flush(); case .replace(let old, let new): if let old { before.append(old) }; if let new { after.append(new) } }
        }
        flush()
        return Array(output.prefix(20))
    }
}
