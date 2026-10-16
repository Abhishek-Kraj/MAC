import Foundation

/// Turns text into a vector via OpenRouter's OpenAI-compatible embeddings API.
///
/// Why this exists: matching a live question to a prepared answer needs to
/// tell "chargeback compute to business units" from "govern ad-hoc compute
/// costs by citizen developers". Those are genuinely different questions
/// that share most of their vocabulary, and no amount of lexical tuning
/// separates them — measured, a BM25 ranker picked the wrong one *and scored
/// it highest*. Embeddings separate them cleanly: correct hits scored +0.071
/// to +0.274, wrong ones +0.003 to +0.024.
///
/// This is not a new dependency. Every request the app already makes goes
/// through OpenRouter with the user's own key, including the key file the
/// user types in Settings. What it costs is one small POST per live question;
/// what it buys is the difference between a prepared answer and a wrong one.
enum EmbeddingService {

    /// OpenAI's large embedding model. `text-embedding-3-small` is cheaper and
    /// faster but measured slightly less separation on this corpus.
    static let model = "openai/text-embedding-3-large"

    /// Documents shorter than this are padded by the API's own tokenizer;
    /// nothing to do here, but worth knowing the floor for a one-word query.
    static let maxBatch = 64

    struct Failure: LocalizedError {
        let underlying: String
        var errorDescription: String? { "Embedding failed: \(underlying)" }
    }

    /// Embeds one string.
    static func embed(_ text: String) async throws -> [Double] {
        let all = try await embed([text])
        guard let first = all.first else { throw Failure(underlying: "empty response") }
        return first
    }

    /// Pulls the vectors out of an embeddings response.
    ///
    /// Split out so it can be tested, and because this is where a subtle bug
    /// once lived: two independent casts (`as? [Double]` then `as? [NSNumber]`)
    /// both succeed on Apple platforms, so every vector was appended twice and
    /// the count check failed on every bank. Embedding therefore never
    /// completed, and live matching could never run at all.
    static func vectors(in rows: [[String: Any]]) -> [[Double]] {
        rows.compactMap { row in
            if let v = row["embedding"] as? [Double] { return v }
            if let v = row["embedding"] as? [NSNumber] { return v.map(\.doubleValue) }
            return nil
        }
    }

    /// Embeds a batch. The bank is embedded once when it is built, so this is
    /// called with tens of entries at a time and once per live question with
    /// a single entry.
    static func embed(_ texts: [String]) async throws -> [[Double]] {
        guard !texts.isEmpty else { return [] }
        let key = UserDefaults.standard.string(forKey: "openRouterAPIKey")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else {
            throw Failure(underlying: "no OpenRouter key — needed to embed")
        }

        var out: [[Double]] = []
        out.reserveCapacity(texts.count)

        for chunk in texts.chunked(maxBatch) {
            let body: [String: Any] = ["model": model, "input": chunk]
            var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/embeddings")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw Failure(underlying: "no HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                let text = String(data: data, encoding: .utf8) ?? ""
                throw Failure(underlying: "HTTP \(http.statusCode) \(text.prefix(140))")
            }
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = parsed["data"] as? [[String: Any]] else {
                throw Failure(underlying: "unexpected response shape")
            }
            out.append(contentsOf: vectors(in: rows))
        }
        guard out.count == texts.count else {
            throw Failure(underlying: "got \(out.count) vectors for \(texts.count) inputs")
        }
        return out
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0, count > size else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}