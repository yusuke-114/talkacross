import Foundation

nonisolated struct ShanghaineseTokenizer {
    static let endToken: Int64 = 0
    static let unknownToken: Int64 = 1
    static let paddingToken: Int64 = 65_000
    static let maximumTokens = 512

    private struct Piece: Decodable {
        let text: String
        let score: Double
        let id: Int64
    }

    private struct Vocabulary: Decodable {
        let pieces: [Piece]
        let symbols: [String]
    }

    private struct Segment {
        let start: Int
        let token: Int64
        let score: Double
    }

    private let pieces: [String: Piece]
    private let symbols: [String]
    private let maximumPieceLength: Int
    private let unknownScore: Double

    init(contentsOf url: URL) throws {
        let vocabulary = try JSONDecoder().decode(Vocabulary.self, from: Data(contentsOf: url))
        pieces = Dictionary(uniqueKeysWithValues: vocabulary.pieces.map { ($0.text, $0) })
        symbols = vocabulary.symbols
        maximumPieceLength = vocabulary.pieces.map { $0.text.unicodeScalars.count }.max() ?? 1
        unknownScore = (vocabulary.pieces.map(\.score).min() ?? 0) - 10
    }

    func encode(_ text: String) throws -> [Int64] {
        let words = text.precomposedStringWithCompatibilityMapping.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }

        // Marian's Chinese SentencePiece vocabulary treats whitespace as ▁.
        let input = Array(("▁" + words.joined(separator: "▁")).unicodeScalars)
        guard input.count <= Self.maximumTokens * maximumPieceLength else {
            throw ShanghaineseNormalizationIssue.textTooLong
        }
        var best = Array<Segment?>(repeating: nil, count: input.count + 1)
        best[0] = Segment(start: 0, token: Self.endToken, score: 0)

        for start in input.indices {
            guard let previous = best[start] else { continue }
            let end = min(start + maximumPieceLength, input.count)
            for stop in (start + 1)...end {
                let text = String(String.UnicodeScalarView(input[start..<stop]))
                let piece = pieces[text]
                if piece == nil, stop != start + 1 { continue }

                let score = previous.score + (piece?.score ?? unknownScore)
                if score > (best[stop]?.score ?? -.infinity) {
                    best[stop] = Segment(start: start, token: piece?.id ?? Self.unknownToken, score: score)
                }
            }
        }

        var reversed: [Int64] = []
        var end = input.count
        while end > 0, let segment = best[end] {
            if segment.token != Self.unknownToken || reversed.last != Self.unknownToken {
                reversed.append(segment.token)
            }
            end = segment.start
            if reversed.count >= Self.maximumTokens {
                throw ShanghaineseNormalizationIssue.textTooLong
            }
        }
        return Array(reversed.reversed()) + [Self.endToken]
    }

    func decode(_ ids: [Int64]) -> String {
        ids.compactMap { id in
            guard id > Self.unknownToken, id != Self.paddingToken, id < Int64(symbols.count) else { return nil }
            return symbols[Int(id)]
        }
        .joined()
        .replacingOccurrences(of: "▁", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
