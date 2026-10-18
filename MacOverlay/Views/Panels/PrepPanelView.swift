import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
        SetupSection(title: "Interview prep") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    statusIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headline)
                            .font(.system(size: 12, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(detail)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                // Actions get their own row. Sharing the headline's row left
                // them truncated to "View 6…" / "Add m…": the headline claimed
                // the width and `StyledButton` is `lineLimit(1)`, so the
                // capsules had nothing left to shrink into.
                HStack(spacing: 6) {
                    if isRunning {
                        Button("Stop") { generator.cancel() }
                            .buttonStyle(.secondaryCompact)
                    } else if isReady {
                        // The way to actually see what was prepared. It was
                        // missing entirely: nothing anywhere set `showBank`,
                        // so the bank was generated and then unreachable.
                        Button("View \(questionCount) questions") { showBank = true }
                            .buttonStyle(.primaryCompact)
                        Button("Add more") { showSetup = true }
                            .buttonStyle(.secondaryCompact)
                    } else {
                        Button(prepareButtonTitle) { showSetup = true }
                            .buttonStyle(.primaryCompact)
                    }
                    Spacer(minLength: 0)
                }

                // Unmissable confirmation. Preparing takes minutes and used to
                // end with no more on screen than the state you started from.
                if isReady { preparedBanner }

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
        .task {
            // Detect the role from the card, not only from the sheet. Detection
            // is one capped call and it is what re-files a bank left under the
            // placeholder — which is inert until it happens, so making it wait
            // for a sheet the user may never open leaves it dead.
            guard isPlaceholderBank || generator.roleName.isEmpty else { return }
            let key = UserDefaults.standard.string(forKey: "openRouterAPIKey")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            await generator.detectRole(context: vm.interviewContext,
                                        resume: vm.interviewResumeText,
                                        key: key)
            let role = generator.roleName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !role.isEmpty, PrepBank.shared.hasBank(forRole: PrepBank.placeholderBankID) {
                _ = PrepBank.shared.renameBank(from: PrepBank.placeholderBankID, to: role)
            }
        }
        .sheet(isPresented: $showSetup) {
            PrepSetupView(onDone: { showSetup = false },
                          onViewBank: { showSetup = false; showBank = true })
        }
        .sheet(isPresented: $showBank) { bankList }
        .sheet(isPresented: $showBackups) { backupList }
        .sheet(item: $editing) { q in
            QuestionEditor(question: q) { editing = nil }
        }
    }

    /// The confirmation that preparing finished, with the count and the way
    /// in. Deliberately the loudest thing in the card: a two-minute job that
    /// ends looking unchanged is indistinguishable from one that failed.
    private var preparedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 1) {
                    // Deliberately not "Prepared — 62 questions". The headline
                    // two lines above already states the count and the role,
                    // so this strip is only worth its space for the thing it
                    // alone knows: where the questions came from. "22 questions"
                    // alone reads as a finished state with no route onward,
                    // which is how a bank of imported questions looks identical
                    // to one researched properly.
                    Text("Prepared")
                        .font(.system(size: 12, weight: .semibold))
                    Text(breakdown).font(.system(size: 10)).foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }

            // The next step, said out loud. These two paths are independent:
            // a bank can be entirely imported, entirely researched, or both.
            // The button for it lives in the action row at the top of the card
            // — repeating it here was a second "Add more" a few points below
            // the first.
            if isPlaceholderBank || researchedCount == 0 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundColor(Design.Accent.brand)
                    Text(isPlaceholderBank
                         ? "Open prep to name this role, then research \(generator.questionCount) more from your job description."
                         : "Research \(generator.questionCount) more from your job description — these are kept and added to.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(Color.green.opacity(0.10)))
        .accessibilityLabel("\(questionCount) questions prepared. \(breakdown)")
    }

    /// Where the questions in the active bank came from. Imported questions
    /// are worth keeping and saying so separately stops them looking like a
    /// shortfall.
    private var breakdown: String {
        var parts: [String] = []
        if importedCount > 0 { parts.append("\(importedCount) yours") }
        if researchedCount > 0 { parts.append("\(researchedCount) researched") }
        if capturedCount > 0 { parts.append("\(capturedCount) captured live") }
        let sources = parts.isEmpty ? "no sources recorded" : parts.joined(separator: " · ")
        let filed = isPlaceholderBank
            ? "Filed as \"Imported\" until you name the role."
            : "For \(activeBankID)."
        return sources + " · " + filed
    }

    private func count(_ source: PrepQuestion.Source) -> Int {
        PrepBank.shared.questions(inBank: activeBankID)
            .filter { $0.source == source }.count
    }

    private var importedCount: Int { count(.user) }
    private var researchedCount: Int { count(.researched) }
    private var capturedCount: Int { count(.captured) }

    /// A bank still named by the placeholder was never given a role, so it is
    /// never selected for live matching — it looks saved and is inert.
    private var isPlaceholderBank: Bool {
        activeBankID == PrepBank.placeholderBankID
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
                .foregroundColor(Design.Accent.brand)
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
    @State private var isImporting = false
    /// Shared, so closing this sheet mid-run does not abandon the work.
    @Bindable private var generator = PrepGenerator.shared
    @State private var pastedQuestions = ""
    @State private var importMessage: String?
    @State private var adoptedNote: String?

    var onDone: () -> Void
    /// Closes this sheet and opens the bank, so a finished run can be
    /// inspected without hunting for where the questions went.
    var onViewBank: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                HStack(spacing: 5) {
                    Text("Role")
                        .font(.system(size: 11, weight: .medium))
                    if generator.roleSource == .detected {
                        // Says where it came from, so it can be checked rather
                        // than trusted.
                        Label("from your job description", systemImage: "sparkles")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                TextField("reading from your job description…", text: $generator.roleName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .disabled(generator.isDetectingRole)
                    .onChange(of: generator.roleName) { _, _ in
                        // Once it is edited by hand it is the user's name, and
                        // detection stops second-guessing them.
                        if !generator.isDetectingRole { generator.markRoleTyped() }
                    }
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

                gapSection

                Divider().padding(.vertical, 2)
                importSection
                status
            }
            .padding(18)
        }
        .frame(width: 560, height: 720)
        .task {
            let key = UserDefaults.standard.string(forKey: "openRouterAPIKey")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            await generator.detectRole(context: vm.interviewContext,
                                       resume: vm.interviewResumeText,
                                       key: key)
            // A bank imported before the role could be detected is filed under
            // "Imported" — not a role, so never selected again and never
            // matched against. Now that the role is known, adopt it, or those
            // questions keep looking saved while doing nothing.
            let role = generator.roleName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !role.isEmpty, PrepBank.shared.hasBank(forRole: PrepBank.placeholderBankID) {
                let moved = PrepBank.shared.renameBank(from: PrepBank.placeholderBankID,
                                                       to: role)
                if moved > 0 { adoptedNote = "\(moved) questions now filed under \(role)." }
            }
        }
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

    /// What the bank does not cover.
    ///
    /// Asked for twice: "will it understand what I know and what I don't?"
    /// Importing a bank answers only the first half. This answers the second,
    /// and it is the half that matters — nobody is caught out by a question
    /// they prepared for; they are caught out by a capability area nothing in
    /// their preparation touches.
    @ViewBuilder
    private var gapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "scope")
                    .font(.system(size: 11))
                    .foregroundColor(Design.Ink.secondary)
                Text("Coverage gaps")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if gapsLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Button(gapReport == nil ? "Check" : "Re-check") { runGapAnalysis() }
                        .buttonStyle(.secondaryCompact)
                        .disabled(gapsLoading)
                }
            }

            if let report = gapReport {
                if report.gaps.isEmpty {
                    Text("Could not read the posting's capability areas. Try again.")
                        .font(.system(size: 10)).foregroundColor(.orange)
                } else {
                    Text(report.needsWork.isEmpty
                         ? "Every capability area in the posting has a prepared question."
                         : "\(report.needsWork.count) of \(report.gaps.count) areas need more.")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                    ForEach(report.needsWork.prefix(8)) { g in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g.line)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(g.risk >= 3 ? .orange : .primary)
                            Text(g.gap)
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if report.solid.isEmpty == false {
                        Text("Covered: \(report.solid.count) areas")
                            .font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
            } else {
                Text("Checks which capability areas this posting tests, against what you have prepared.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }

    @State private var gapReport: GapAnalyser.Report?
    @State private var gapsLoading = false

    private func runGapAnalysis() {
        let role = generator.roleName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bank = role.isEmpty ? (PrepBank.shared.activeBankID.isEmpty
            ? (PrepBank.shared.banks.first?.id ?? "") : PrepBank.shared.activeBankID) : role
        let questions = PrepBank.shared.questions(inBank: bank)
        guard !questions.isEmpty else {
            gapReport = nil
            return
        }
        gapsLoading = true
        let key = UserDefaults.standard.string(forKey: "openRouterAPIKey")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        Task {
            let report = await GapAnalyser.analyse(
                jd: vm.interviewContext, role: role.isEmpty ? bank : role,
                bank: questions, key: key)
            gapReport = report
            gapsLoading = false
        }
    }

    /// Bring your own questions.
    ///
    /// A mock interview run on another tool is worth more than a fresh research
    /// pass: those are the questions a real interviewer asked, and the answers
    /// are already in your own words. Pasting them in beats paying a model to
    /// guess at them again.
    @ViewBuilder
    private var importSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 11))
                    .foregroundColor(Design.Ink.secondary)
                Text("Bring your own questions")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button("Choose file…") { pickImportFile() }
                    .buttonStyle(.secondaryCompact)
            }

            TextEditor(text: $pastedQuestions)
                .scrollContentBackground(.hidden)
                .font(.system(size: 11))
                .padding(6)
                .frame(height: 74)
                .background(RoundedRectangle(cornerRadius: 8).fill(Design.Surface.inputFill))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Design.Surface.hairline, lineWidth: 0.5))
                .overlay(alignment: .topLeading) {
                    if pastedQuestions.isEmpty {
                        Text("Paste questions and answers here — Q: … / A: … is the easiest.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 11).padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }

            if let adoptedNote {
                Label(adoptedNote, systemImage: "folder.badge.gearshape")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            if let message = importMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundColor(importSucceeded ? .green : .orange)
            }

            HStack(spacing: 8) {
                Button("Add pasted") { importPasted() }
                    .buttonStyle(.primaryCompact)
                    .disabled(pastedQuestions.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty || isImporting)
                Spacer()
                if isImporting { ProgressView().controlSize(.mini) }
            }
        }
    }

    private var importSucceeded: Bool {
        if case .some(let m) = importMessage { return m.hasPrefix("Added ") }
        return false
    }

    private func pickImportFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // Built by extension rather than by constant: .json5 and .markdown have
        // no UTType static on the deployment target, and a question bank
        // arrives as whatever the other tool exported.
        let extras = ["txt", "md", "json", "markdown", "csv", "text"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = [.plainText, .json] + extras
        panel.message = "Choose a question bank exported from a mock interview."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try PrepBankImporter.readFile(at: url)
            pastedQuestions = text
            importMessage = nil
        } catch {
            importMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func importPasted() {
        let text = pastedQuestions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let role = generator.roleName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bank = role.isEmpty ? PrepBank.placeholderBankID : role
        let result = PrepBankImporter.parse(text)
        guard !result.pairs.isEmpty else {
            importMessage = "No question-and-answer pairs found. Try Q: … / A: … on separate lines."
            return
        }
        PrepBank.shared.activeBankID = bank
        PrepBank.shared.add(questions: result.pairs.map {
            PrepQuestion(question: $0.question, answer: $0.answer,
                         source: .user, topic: $0.topic, bankID: bank)
        })
        // Embedding is what makes imported questions matchable live, so it is
        // the last step and not an afterthought — without it they sit in the
        // bank doing nothing.
        isImporting = true
        Task {
            // Anything too long to read between questions is shortened first,
            // so what appears live is speakable. The original is kept.
            let key = UserDefaults.standard.string(forKey: "openRouterAPIKey")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var shortened = 0
            for pair in result.pairs
            where pair.answer.count > AnswerCondenser.longAnswerThreshold {
                if let spoken = await AnswerCondenser.condense(
                    pair.answer, question: pair.question, key: key) {
                    if var stored = PrepBank.shared.questions(inBank: bank)
                        .first(where: { $0.question == pair.question }) {
                        stored.spokenAnswer = spoken
                        PrepBank.shared.update(stored)
                        shortened += 1
                    }
                }
            }

            await PreparedAnswerLookup.shared.embedBank(bank)
            isImporting = false
            let failed = PreparedAnswerLookup.shared.lastError != nil
            importMessage = failed
                ? "Added \(result.pairs.count), but matching is not ready: "
                  + (PreparedAnswerLookup.shared.lastError ?? "unknown error")
                : "Added \(result.pairs.count) questions to \(bank) (\(formatName(result.format)))"
                  + (shortened > 0
                     ? ". \(shortened) long \(shortened == 1 ? "answer" : "answers") shortened to say out loud; full text kept."
                     : "")
            if !failed { pastedQuestions = "" }
        }
    }

    private func formatName(_ f: PrepBankImporter.Format) -> String {
        switch f {
        case .json:       return "JSON"
        case .labelled:   return "Q:/A: text"
        case .markdown:   return "markdown"
        case .transcript: return "transcript"
        }
    }

    @ViewBuilder
    private var status: some View {
        if let guidance = generator.guidance {
            Text(guidance).font(.system(size: 10)).foregroundColor(.secondary)
        }
        switch generator.stage {
        case .done(let count):
            HStack(spacing: 6) {
                Label("Prepared \(count) questions.", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.green)
                Spacer()
                Button("View them") { onDone(); onViewBank() }
                    .buttonStyle(.secondaryCompact)
            }
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
