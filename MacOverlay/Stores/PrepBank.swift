import Foundation
import Observation

/// One question prepared for an interview, with the answer ready to read.
///
/// The point of the bank is that the answer is *already written* when the
/// question comes up, so nothing has to be generated live. That turns a
/// ~2 s wait and a token spend into a sub-millisecond lookup, and lets the
/// answer be reviewed while there is still time to fix a wrong one.
struct PrepQuestion: Identifiable, Hashable, Codable {
    enum Source: String, Codable {
        /// Fetched by the research pass from a JD.
        case researched
        /// Typed in by the user.
        case user
        /// Caught during a real interview because the bank missed it.
        case captured
    }

    let id: UUID
    var question: String
    var answer: String
    var source: Source
    /// "capacity", "governance", "migration" — free text, used for grouping.
    var topic: String?
    /// Which bank this belongs to. Keyed by *role*, not by posting, so the
    /// same bank serves every interview for that role. See `PrepBank`.
    var bankID: String
    /// How often the live matcher has fired on this question. After a couple
    /// of interviews this is how you tell which questions are actually asked.
    var timesMatched: Int
    var lastMatchedAt: Date?
    var createdAt: Date

    init(id: UUID = UUID(),
         question: String,
         answer: String = "",
         source: Source = .user,
         topic: String? = nil,
         bankID: String,
         timesMatched: Int = 0,
         lastMatchedAt: Date? = nil,
         createdAt: Date = Date()) {
        self.id = id
        self.question = question
        self.answer = answer
        self.source = source
        self.topic = topic
        self.bankID = bankID
        self.timesMatched = timesMatched
        self.lastMatchedAt = lastMatchedAt
        self.createdAt = createdAt
    }
}

/// A set of prepared questions for a role.
///
/// Keyed by role rather than by job posting, deliberately. A bank scoped to
/// one JD has to be regenerated and re-reviewed for every interview and never
/// compounds; a bank scoped to "Fabric Platform Lead" gets reused, grows as
/// questions are missed, and after a couple of interviews is worth more than
/// anything a fresh research pass can produce.
@Observable
@MainActor
final class PrepBank {
    static let shared = PrepBank()

    private static let filename = "prepBank.json"

    private(set) var questions: [PrepQuestion] = []
    /// The bank currently being viewed / edited on the setup screen.
    var activeBankID: String = ""
    /// Questions caught live but not yet accepted into a bank.
    private(set) var pendingCaptures: [PrepQuestion] = []

    private init() {
        if let loaded = JSONStore.load([PrepQuestion].self, from: Self.filename) {
            questions = loaded
        }
        if activeBankID.isEmpty { activeBankID = questions.first?.bankID ?? "" }
    }

    // MARK: - Queries

    var banks: [(id: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for q in questions {
            if counts[q.bankID] == nil { order.append(q.bankID) }
            counts[q.bankID, default: 0] += 1
        }
        return order.map { (id: $0, count: counts[$0] ?? 0) }
    }

    func questions(inBank id: String) -> [PrepQuestion] {
        questions.filter { $0.bankID == id }
    }

    /// True when this role already has a bank worth showing. Research should
    /// not run and re-generate questions the user already has.
    func hasBank(forRole role: String) -> Bool {
        !questions(inBank: role).isEmpty
    }

    // MARK: - Mutations

    @discardableResult
    func add(_ q: PrepQuestion) -> PrepQuestion {
        questions.append(q)
        persist()
        return q
    }

    func add(questions new: [PrepQuestion]) {
        questions.append(contentsOf: new)
        persist()
    }

    func update(_ q: PrepQuestion) {
        guard let i = questions.firstIndex(where: { $0.id == q.id }) else { return }
        questions[i] = q
        persist()
    }

    func delete(_ q: PrepQuestion) {
        questions.removeAll { $0.id == q.id }
        persist()
    }

    func deleteBank(_ id: String) {
        questions.removeAll { $0.bankID == id }
        if activeBankID == id { activeBankID = banks.first?.id ?? "" }
        persist()
    }

    // MARK: - Live matching bookkeeping

    /// Records that the matcher fired on this question, so the bank learns
    /// which questions are actually asked.
    func recordMatch(_ id: UUID) {
        guard let i = questions.firstIndex(where: { $0.id == id }) else { return }
        questions[i].timesMatched += 1
        questions[i].lastMatchedAt = Date()
        persist()
    }

    // MARK: - Missed-question capture

    /// Called when a question arrives that the bank could not confidently
    /// answer. Held separately so the user decides whether it earns a place
    /// rather than the bank silently growing during an interview.
    func captureMissed(question: String, bankID: String, answer: String = "") {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return }
        // Don't stack duplicates of the same miss.
        let key = PrepMatcher.normalise(trimmed)
        guard !pendingCaptures.contains(where: { PrepMatcher.normalise($0.question) == key })
        else { return }
        pendingCaptures.append(
            PrepQuestion(question: trimmed, answer: answer,
                         source: .captured, bankID: bankID))
    }

    var pendingCaptureCount: Int { pendingCaptures.count }

    /// Moves captured questions into the bank, marking them as `captured`.
    @discardableResult
    func acceptPendingCaptures(into bankID: String) -> Int {
        let n = pendingCaptures.count
        guard n > 0 else { return 0 }
        questions.append(contentsOf: pendingCaptures.map { q in
            var q = q
            q.bankID = bankID
            q.source = .captured
            return q
        })
        pendingCaptures.removeAll()
        persist()
        return n
    }

    func discardPendingCaptures() { pendingCaptures.removeAll() }

    // MARK: - Persistence

    private func persist() {
        JSONStore.save(questions, to: Self.filename)
    }
}