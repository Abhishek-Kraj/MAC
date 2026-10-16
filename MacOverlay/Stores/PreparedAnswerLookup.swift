import Foundation
import Observation

/// Finds a prepared answer for what the interviewer just said.
///
/// Order of preference:
///   1. A semantic match on embeddings — the only path trusted at a realistic
///      bank size, because it is the only one measured to never return a wrong
///      answer.
///   2. Nothing. It returns nil and the caller generates.
///
/// There is deliberately no lexical fallback on the live path. BM25 was
/// measured at 50 questions and put a *wrong* entry first while scoring it
/// highest; a cheap fallback that is wrong on the one occasion it gets used is
/// worse than no fallback at all, because the user cannot tell the difference.
@Observable
@MainActor
final class PreparedAnswerLookup {
    static let shared = PreparedAnswerLookup()

    /// Set when the last lookup could not be made — no key, no network, an
    /// HTTP error. Surfaced so Settings can explain why matching is inert.
    private(set) var lastError: String?
    private(set) var lastMatchWasSemantic = false

    /// Embeds every question in a bank that does not already have a vector.
    /// Called after research, or after the user edits the bank. Cheap: the
    /// whole bank goes up in one or two requests.
    @discardableResult
    func embedBank(_ bankID: String) async -> Int {
        let bank = PrepBank.shared
        let pending = bank.questions(inBank: bankID)
            .filter { $0.embedding == nil }
        guard !pending.isEmpty else { return 0 }

        do {
            let vectors = try await EmbeddingService.embed(pending.map(\.question))
            for (question, vector) in zip(pending, vectors) {
                var updated = question
                updated.embedding = vector
                bank.update(updated)
            }
            lastError = nil
            return pending.count
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
            return 0
        }
    }

    /// Prepared answer for `transcript`, or nil when nothing is confident.
    ///
    /// One network call for the query. The bank vectors are already local, so
    /// the comparison afterwards is a few microseconds of arithmetic.
    ///
    /// `timeout` bounds the request. An interview answer that waits forever for
    /// a lookup is worse than one that simply generates, so a slow or dead
    /// network degrades to generation rather than blocking the user.
    func preparedAnswer(for transcript: String, inBank bankID: String,
                        timeout: TimeInterval = 3.0) async -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return nil }

        let bank = PrepBank.shared.questions(inBank: bankID)
        guard !bank.isEmpty else { return nil }
        guard bank.contains(where: { $0.embedding != nil }) else {
            lastMatchWasSemantic = false
            return nil
        }

        let vector: [Double]
        do {
            vector = try await withTimeout(seconds: timeout) {
                try await EmbeddingService.embed(trimmed)
            }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
            return nil
        }

        guard let hit = PrepMatcher.semanticBest(query: vector, against: bank) else {
            lastMatchWasSemantic = false
            return nil
        }
        let answer = hit.question.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return nil }

        lastError = nil
        lastMatchWasSemantic = true
        PrepBank.shared.recordMatch(hit.question.id)
        return answer
    }
}

/// Fails with `TimeoutError` if the operation outlives its budget, so a dead
/// network degrades to "generate an answer instead" rather than hanging the
/// person waiting to speak.
private struct TimeoutError: LocalizedError {
    var errorDescription: String? { "timed out" }
}

func withTimeout<T: Sendable>(seconds: TimeInterval,
                               _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw TimeoutError() }
        return first
    }
}
