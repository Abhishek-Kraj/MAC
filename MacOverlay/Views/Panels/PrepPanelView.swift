import SwiftUI

/// Interview preparation, on the interview setup screen.
///
/// Deliberately collapsed into one card rather than a permanent form. The
/// setup screen's job is to get you into the interview; the posting, the
/// background and the forty generated questions are a detour that most
/// sessions do not need. So this shows state, and opens a sheet when you
/// actually want to do the work.
struct PrepPanelView: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var showSetup = false
    @State private var showBank = false
    @State private var showBackups = false
    @State private var editing: PrepQuestion?

    /// The role whose bank applies here — the one in Context, or the most
    /// recent bank.
    private var activeBankID: String {
        if !PrepBank.shared.activeBankID.isEmpty { return PrepBank.shared.activeBankID }
        return PrepBank.shared.banks.first?.id ?? ""
    }

    private var questionCount: Int {
        PrepBank.shared.questions(inBank: activeBankID).count
    }

    private var isReady: Bool {
        questionCount > 0
            && PrepBank.shared.questions(inBank: activeBankID).contains { $0.embedding != nil }
    }

    var body: some View {
        prepSectionCard(title: "Interview prep", systemImage: "text.book.closed") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: isReady ? "checkmark.circle.fill"
                              : (questionCount > 0 ? "exclamationmark.circle.fill" : "circle"))
                        .font(.system(size: 13))
                        .foregroundColor(isReady ? .green
                                         : (questionCount > 0 ? .orange : .secondary.opacity(0.6)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline)
                            .font(.system(size: 12, weight: .medium))
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(isReady ? "Review" : "Set up") {
                        isReady ? (showBank = true) : (showSetup = true)
                    }
                    .buttonStyle(.secondaryCompact)
                }

                if PrepBank.shared.pendingCaptureCount > 0 {
                    capturedNotice
                }
            }
        }
        .sheet(isPresented: $showSetup) { PrepSetupView(onDone: { showSetup = false }) }
        .sheet(isPresented: $showBank) { bankList }
        .sheet(isPresented: $showBackups) { backupList }
        .sheet(item: $editing) { q in
            QuestionEditor(question: q) { editing = nil }
        }
    }

    private var headline: String {
        if isReady { return "\(questionCount) prepared questions for \(activeBankID)" }
        if questionCount > 0 { return "\(questionCount) questions, but not yet matched" }
        return "Not prepared yet"
    }

    private var detail: String {
        if isReady { return "Answers appear instantly when a question matches." }
        if questionCount > 0 { return "Open review to finish matching them." }
        return "Generate questions and answers from your job description."
    }

    @ViewBuilder
    private var capturedNotice: some View {
        let n = PrepBank.shared.pendingCaptureCount
        HStack(spacing: 8) {
            Text("\(n) question\(n == 1 ? "" : "s") asked but not in the bank")
                .font(.system(size: 10))
                .foregroundColor(.orange)
            Spacer()
            Button("Add them") {
                PrepBank.shared.acceptPendingCaptures(into: activeBankID)
            }
            .buttonStyle(.secondaryCompact)
            Button("Discard") { PrepBank.shared.discardPendingCaptures() }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Bank

    private var bankList: some View {
        NavigationStack {
            List {
                ForEach(PrepBank.shared.banks, id: \.id) { entry in
                    Section("\(entry.id) — \(entry.count) questions") {
                        ForEach(PrepBank.shared.questions(inBank: entry.id)) { q in
                            button(q)
                        }
                        .onDelete { offsets in
                            let items = PrepBank.shared.questions(inBank: entry.id)
                            for i in offsets { PrepBank.shared.delete(items[i]) }
                        }
                    }
                }
                Section {
                    Button("Backups…") { showBackups = true; showBank = false }
                }
            }
            .navigationTitle("Interview prep")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showBank = false }
                }
            }
        }
        .frame(width: 620, height: 520)
    }

    private func button(_ q: PrepQuestion) -> some View {
        Button { editing = q } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(q.question)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let t = q.topic {
                        Text(t.uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                    if q.answer.isEmpty {
                        Text("NO ANSWER YET")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.orange)
                    }
                    if q.embedding == nil {
                        Text("NOT MATCHED")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.orange.opacity(0.8))
                    }
                    if q.timesMatched > 0 {
                        Text("asked \(q.timesMatched)×")
                            .font(.system(size: 9))
                            .foregroundColor(.green.opacity(0.9))
                    }
                    Spacer()
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Backups

    private var backupList: some View {
        NavigationStack {
            List {
                Section("Automatic snapshots") {
                    ForEach(PrepBankBackup.snapshots()) { snap in
                        HStack {
                            Text(snap.name).font(.system(size: 11))
                            Spacer()
                            Button("Restore") {
                                try? PrepBankBackup.restore(from: snap.url)
                                showBackups = false
                            }
                            .buttonStyle(.secondaryCompact)
                        }
                    }
                }
                Section {
                    Button("Save a copy…") {
                        let panel = NSSavePanel()
                        panel.nameFieldStringValue = "interview-prep.json"
                        if panel.runModal() == .OK, let url = panel.url {
                            _ = PrepBankBackup.export(to: url)
                        }
                    }
                    Button("Load from a file…") {
                        let panel = NSOpenPanel()
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            try? PrepBankBackup.restore(from: url)
                            showBackups = false
                        }
                    }
                }
            }
            .navigationTitle("Backups")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showBackups = false }
                }
            }
        }
        .frame(width: 520, height: 420)
    }
}

// MARK: - Setup sheet

/// The actual prep work: role, posting, background, generate. Shown as a sheet
/// so the setup screen stays about starting the interview.
struct PrepSetupView: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var generator = PrepGenerator()

    var onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                TextField("Role — e.g. Fabric Platform Lead", text: $generator.roleName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .help("The bank is filed under this, so name the role, not the posting.")

                posting

                HStack(spacing: 8) {
                    Button {
                        generator.useContext(vm.interviewContext)
                        generator.resumeText = vm.interviewResumeText
                        Task { await generator.generate() }
                    } label: {
                        if generator.isRunning {
                            HStack(spacing: 5) {
                                ProgressView().controlSize(.small)
                                Text(generator.stage == .researching
                                     ? "Researching…" : "Matching…")
                            }
                            .font(.system(size: 12))
                        } else {
                            Text(PrepBank.shared.hasBank(forRole: roleKey)
                                 ? "Add more questions" : "Prepare questions")
                                .font(.system(size: 12))
                        }
                    }
                    .buttonStyle(.primaryCompact)
                    .disabled(!generator.canGenerate)

                    Stepper("\(generator.questionCount) questions",
                            value: $generator.questionCount, in: 10...50, step: 5)
                        .font(.system(size: 11))
                        .fixedSize()

                    Spacer()
                    Button("Done") { onDone() }
                        .buttonStyle(.secondaryCompact)
                }

                status
            }
            .padding(18)
        }
        .frame(width: 560, height: 560)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Interview prep").font(.system(size: 15, weight: .semibold))
            Text("Build a bank of likely questions with answers you can say out loud.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private var roleKey: String {
        generator.roleName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Everything prep will read, with a tick per source, so it is visible
    /// rather than assumed. The point is that you do not retype any of it.
    @ViewBuilder
    private var posting: some View {
        let context = vm.interviewContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContext = context.count > 40
        let hasCV = vm.interviewResumeText.count > 80
        let hasOwn = !generator.jobDescription.isEmpty

        VStack(alignment: .leading, spacing: 6) {
            sourceRow(hasOwn ? "Posting" : "Context", ok: hasOwn || hasContext,
                      detail: hasOwn ? "pasted here"
                        : hasContext ? "\(context.count) characters"
                        : "empty — add the JD under Context")
            sourceRow("Résumé", ok: hasCV,
                      detail: hasCV
                        ? "\(vm.interviewResumeText.count) characters from \(vm.interviewResumeFileURL?.lastPathComponent ?? "file")"
                        : "none attached — answers stay general")
            if !hasOwn {
                TextEditor(text: $generator.jobDescription)
                    .font(.system(size: 11))
                    .frame(minHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
            }
        }
    }

    private func sourceRow(_ label: String, ok: Bool, detail: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 11))
                .foregroundColor(ok ? .green : .secondary.opacity(0.6))
            Text(label).font(.system(size: 11, weight: .medium))
            Text(detail)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
        }
    }

    @ViewBuilder
    private var status: some View {
        if let guidance = generator.guidance {
            Text(guidance).font(.system(size: 10)).foregroundColor(.secondary)
        }
        switch generator.stage {
        case .done(let count):
            Label("Added \(count) questions. Ready to use.",
                  systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(.green)
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.orange)
        default:
            EmptyView()
        }
    }
}

// MARK: - Question editor

struct QuestionEditor: View {
    @State private var question: String
    @State private var answer: String
    let original: PrepQuestion
    var onClose: () -> Void

    init(question: PrepQuestion, onClose: @escaping () -> Void) {
        original = question
        _question = State(initialValue: question.question)
        _answer = State(initialValue: question.answer)
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Question").font(.system(size: 11, weight: .semibold))
            TextField("", text: $question, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)

            Text("Answer you can say out loud").font(.system(size: 11, weight: .semibold))
            TextField("", text: $answer, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(4...12)

            HStack {
                Text(original.timesMatched > 0
                     ? "Matched \(original.timesMatched) time\(original.timesMatched == 1 ? "" : "s")"
                     : "Not matched yet")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                Button("Delete", role: .destructive) {
                    PrepBank.shared.delete(original)
                    onClose()
                }
                Button("Save") {
                    var updated = original
                    updated.question = question
                    updated.answer = answer
                    PrepBank.shared.update(updated)
                    PrepBankBackup.snapshot()
                    onClose()
                }
                .buttonStyle(.primaryCompact)
            }
        }
        .padding(16)
        .frame(width: 520, height: 340)
    }
}

/// Matches the card used elsewhere on the interview setup screen, which is
/// private to that view and cannot be reused here.
private func prepSectionCard<Content: View>(
    title: String, systemImage: String,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Design.Ink.secondary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Design.Ink.primary)
        }
        content()
    }
}