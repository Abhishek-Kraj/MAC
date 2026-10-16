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
    @Bindable private var generator = PrepGenerator.shared
    @State private var spin: Double = 0
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
                    statusIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline)
                            .font(.system(size: 12, weight: .medium))
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if isRunning {
                        Button("Stop") { generator.cancel() }
                            .buttonStyle(.secondaryCompact)
                    }
                    // Styled by a branch rather than a ternary: the two
                    // styles are different concrete types and will not unify.
                    if isReady {
                        Button(prepareButtonTitle) { showSetup = true }
                            .buttonStyle(.secondaryCompact)
                    } else {
                        Button(prepareButtonTitle) { showSetup = true }
                            .buttonStyle(.primaryCompact)
                    }
                }

                if isRunning { progress.animation(.easeInOut(duration: 0.2), value: isRunning) }

                // What prep would read, on the card itself. Attaching a CV and
                // seeing no sign of it anywhere is what makes the whole panel
                // look broken.
                if vm.interviewResumeFileURL != nil ||
                   !vm.interviewContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sourcesSummary
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

    private var isRunning: Bool { generator.isRunning }

    /// Labelled for the action, not for the state. Someone scanning the setup
    /// screen should be able to find "prepare" without reading the body text.
    private var prepareButtonTitle: String {
        if isRunning { return "Preparing…" }
        if questionCount > 0 { return "Prepare more" }
        if generator.stage.isFailure { return "Try again" }
        return "Prepare interview"
    }

    /// Spins while preparing. A static glyph reads as decoration; the motion
    /// is what tells you a two-minute job is actually running and that you can
    /// walk away from it.
    @ViewBuilder
    private var statusIcon: some View {
        if isRunning {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13))
                .foregroundColor(.accentColor)
                .rotationEffect(.degrees(spin))
                .onAppear {
                    withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                        spin = 360
                    }
                }
        } else {
            Image(systemName: isReady ? "checkmark.circle.fill"
                      : (questionCount > 0 || generator.stage.isFailure
                         ? "exclamationmark.triangle.fill" : "circle.dashed"))
                .font(.system(size: 13))
                .foregroundColor(isReady ? .green
                             : (questionCount > 0 || generator.stage.isFailure
                                ? .orange : .secondary.opacity(0.6)))
        }
    }

    private var headline: String {
        if isRunning { return "Preparing…" }
        if isReady { return "\(questionCount) prepared questions for \(activeBankID)" }
        if questionCount > 0 { return "\(questionCount) questions, but not yet matched" }
        // A failed run is NOT the same as nothing prepared, and saying
        // "nothing prepared yet" after a failure sends you off to re-upload a
        // CV that was never the problem. The reason belongs here, on the card
        // you are looking at — not in a sheet that closed itself.
        if case .failed(let why) = generator.stage { return "Preparation failed" }
        if let blocker = generator.guidance { return blocker }
        return "No questions prepared yet"
    }

    private var detail: String {
        if isRunning { return "You can start the interview now — it will use what is ready." }
        if isReady { return "Answers appear instantly when a question matches." }
        if questionCount > 0 { return "Open review to finish matching them." }
        if case .failed(let why) = generator.stage { return why }
        if let blocker = generator.guidance {
            return "Your CV and context are already saved — only this is missing."
        }
        return "Do this before you start. Takes a minute or two."
    }

    /// One line, on the card: which sources are in play. Mirrors the detail
    /// in the sheet so the answer to "is it using my CV?" is visible before
    /// opening anything.
    private var sourcesSummary: some View {
        HStack(spacing: 5) {
            if vm.isPreparingResume {
                ProgressView().controlSize(.mini)
                Text("Reading résumé…")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else if let problem = vm.interviewResumeError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                Text(problem)
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !vm.interviewResumeText.isEmpty {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.green)
                Text("CV · \(vm.interviewResumeText.count) chars")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            if !vm.interviewContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if vm.isPreparingResume == false && vm.interviewResumeError == nil
                    && !vm.interviewResumeText.isEmpty { Text("·").foregroundColor(.secondary) }
                Image(systemName: "text.alignleft")
                    .font(.system(size: 9))
                    .foregroundColor(.green)
                Text("Context · \(vm.interviewContext.count) chars")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var progress: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Indeterminate, because the model decides how long research takes
            // and no honest number is available to show.
            ProgressView()
                .controlSize(.small)
                .scaleEffect(x: 1, y: 1.2, anchor: .center)
            Text(generator.stage == .researching
                 ? "Researching the role and writing questions…"
                 : "Embedding, so answers can be matched live…")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.leading, 21)
        .transition(.opacity)
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
    /// Shared, so closing this sheet mid-run does not abandon the work.
    @Bindable private var generator = PrepGenerator.shared

    var onDone: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                // Required, and marked as such. It gates generation, and as a
                // bare placeholder it read as optional — leaving it blank
                // disabled the button with no visible reason.
                HStack(spacing: 5) {
                    Text("Role")
                        .font(.system(size: 11, weight: .medium))
                    Text("required").font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer()
                }
                TextField("e.g. Fabric Platform Lead", text: $generator.roleName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .help("The bank is filed under this, so name the role, not the posting.")

                posting

                HStack(spacing: 8) {
                    Button {
                        generator.start(context: vm.interviewContext,
                                        resume: vm.interviewResumeText)
                        // Deliberately does NOT close. The progress and any
                        // failure are reported in this sheet; closing it here
                        // hid both, which is how a failed run came to look
                        // like nothing had ever been attempted.
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
            sourceRow("Résumé",
                      ok: hasCV,
                      failed: vm.interviewResumeError != nil,
                      detail: hasCV
                        ? "\(vm.interviewResumeText.count) characters from \(vm.interviewResumeFileURL?.lastPathComponent ?? "file")"
                        : (vm.interviewResumeError.map { "attached but unreadable — \($0)" }
                           ?? "none attached — answers stay general"))
            if !hasOwn {
                TextEditor(text: $generator.jobDescription)
                    .font(.system(size: 11))
                    .frame(minHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
            }
        }
    }

    private func sourceRow(_ label: String, ok: Bool, failed: Bool = false,
                           detail: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill"
                      : (failed ? "exclamationmark.triangle.fill" : "circle.dashed"))
                .font(.system(size: 11))
                .foregroundColor(ok ? .green
                             : (failed ? .orange : .secondary.opacity(0.6)))
            Text(label).font(.system(size: 11, weight: .medium))
            Text(detail)
                .font(.system(size: 10))
                .foregroundColor(failed ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
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