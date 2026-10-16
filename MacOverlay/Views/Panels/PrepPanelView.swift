import SwiftUI

/// Interview preparation: build a bank of questions with prepared answers
/// from a job description, then review and edit what came back.
///
/// The bank is keyed by *role*, not by posting, so it is reused across every
/// interview for that role and grows as questions are missed in real ones.
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

struct PrepPanelView: View {
    @Environment(OverlayViewModel.self) private var vm
    @State private var generator = PrepGenerator()
    @State private var showBank = false
    @State private var showBackups = false
    @State private var editing: PrepQuestion?
    @State private var draftQuestion = ""
    @State private var draftAnswer = ""

    var body: some View {
        prepSectionCard(title: "Interview prep", systemImage: "text.book.closed") {
            VStack(alignment: .leading, spacing: 12) {
                if !generator.roleName.isEmpty || !generator.jobDescription.isEmpty || !PrepBank.shared.questions.isEmpty {
                    builder
                }
                status
                bankSummary
            }
        }
        .sheet(isPresented: $showBank) { bankList }
        .sheet(isPresented: $showBackups) { backupList }
        .sheet(item: $editing) { q in questionEditor(q) }
    }

    // MARK: - Builder

    @ViewBuilder
    private var builder: some View {
        TextField("Role — e.g. Fabric Platform Lead", text: $generator.roleName)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
            .help("The bank is filed under this, so name the role rather than the posting.")

        Text("Job description")
            .font(.system(size: 11, weight: .semibold))
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            TextEditor(text: $generator.jobDescription)
                .scrollContentBackground(.hidden)
                .font(.system(size: 11))
                .padding(8)
                .frame(minHeight: 100, maxHeight: 190)
            if generator.jobDescription.isEmpty {
                Text("Paste the posting. Research and 40 questions take about a minute.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.5))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }

        Text("Your background (optional)")
            .font(.system(size: 11, weight: .semibold))
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            TextEditor(text: $generator.background)
                .scrollContentBackground(.hidden)
                .font(.system(size: 11))
                .padding(8)
                .frame(minHeight: 54, maxHeight: 110)
            if generator.background.isEmpty {
                Text("Keeps the answers in your voice, and stops the model inventing projects.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.5))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }

        HStack(spacing: 8) {
            Button {
                Task { await generator.generate() }
            } label: {
                if generator.isRunning {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text(generator.stage == .researching ? "Researching…" : "Matching…")
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
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var status: some View {
        if let guidance = generator.guidance {
            Text(guidance)
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.85))
        }
        switch generator.stage {
        case .done(let count):
            Label("Added \(count) questions to \(roleKey). They are matched live during an interview.",
                  systemImage: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(.green)
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(.orange)
        default:
            EmptyView()
        }
    }

    private var roleKey: String {
        generator.roleName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Bank summary

    @ViewBuilder
    private var bankSummary: some View {
        let banks = PrepBank.shared.banks
        if !banks.isEmpty || PrepBank.shared.pendingCaptureCount > 0 {
            VStack(alignment: .leading, spacing: 6) {
                if PrepBank.shared.pendingCaptureCount > 0 {
                    let n = PrepBank.shared.pendingCaptureCount
                    HStack(spacing: 8) {
                        Text("\(n) question\(n == 1 ? "" : "s") asked but not in the bank.")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                        Spacer()
                        Button("Add to bank") {
                            PrepBank.shared.acceptPendingCaptures(into: banks.first?.id ?? roleKey)
                        }
                        .buttonStyle(.secondaryCompact)
                        Button("Discard") { PrepBank.shared.discardPendingCaptures() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Button("Review questions") { showBank = true }
                        .buttonStyle(.secondaryCompact)
                        .disabled(banks.isEmpty)
                    Button("Backups") { showBackups = true }
                        .buttonStyle(.secondaryCompact)
                        .disabled(PrepBankBackup.snapshots().isEmpty)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Bank list

    private var bankList: some View {
        NavigationStack {
            List {
                ForEach(PrepBank.shared.banks, id: \.id) { entry in
                    Section {
                        ForEach(PrepBank.shared.questions(inBank: entry.id)) { q in
                            row(q)
                        }
                        .onDelete { offsets in
                            let items = PrepBank.shared.questions(inBank: entry.id)
                            for i in offsets { PrepBank.shared.delete(items[i]) }
                        }
                    } header: {
                        HStack {
                            Text("\(entry.id) — \(entry.count) questions")
                            Spacer()
                        }
                    }
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

    private func row(_ q: PrepQuestion) -> some View {
        Button { draftQuestion = q.question; draftAnswer = q.answer; editing = q } label: {
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

    private func questionEditor(_ q: PrepQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Question").font(.system(size: 11, weight: .semibold))
            TextField("", text: $draftQuestion, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)

            Text("Answer you can say out loud").font(.system(size: 11, weight: .semibold))
            TextField("", text: $draftAnswer, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(4...12)

            HStack {
                Text(q.timesMatched > 0
                     ? "Matched \(q.timesMatched) time\(q.timesMatched == 1 ? "" : "s")"
                     : "Not matched yet")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Delete", role: .destructive) {
                    PrepBank.shared.delete(q)
                    editing = nil
                }
                Button("Save") {
                    var updated = q
                    updated.question = draftQuestion
                    updated.answer = draftAnswer
                    PrepBank.shared.update(updated)
                    PrepBankBackup.snapshot()
                    editing = nil
                }
                .buttonStyle(.primaryCompact)
            }
        }
        .padding(16)
        .frame(width: 520, height: 340)
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