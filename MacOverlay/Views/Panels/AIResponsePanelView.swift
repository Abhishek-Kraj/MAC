import SwiftUI
import AppKit

struct AIResponsePanelView: View {
    @Environment(OverlayViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Response")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if vm.hasPreparedAnswer { preparedBadge }
                if !vm.aiResponse.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(vm.aiResponse, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy response")
                }
                Button { vm.aiResponse = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if vm.hasPreparedAnswer && !vm.isShowingPrepared {
                        Text("Showing the answer generated live. Your prepared answer is one click away.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12).padding(.bottom, 2)
                    }
                    if vm.isSendingToAI && !vm.hasPreparedAnswer {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.75)
                            Text("Thinking…")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    } else {
                        MarkdownResponseView(text: vm.aiResponse, baseSize: 12 * vm.textScale,
                                             codeSize: 11 * vm.textScale)
                            .padding(12)
                            .transition(.opacity)
                    }
                }
            }
            .hiddenScrollGutter()
            .frame(maxHeight: 300)
            .animation(.easeInOut(duration: 0.2), value: vm.isSendingToAI)
            .animation(.easeInOut(duration: 0.15), value: vm.isShowingPrepared)
        }
    }

    /// Marks the answer as coming from the bank rather than the model, and
    /// offers the generated one for comparison. A prepared answer that looks
    /// like any other answer is a prepared answer nobody will check.
    private var preparedBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 8))
                .foregroundColor(.white)
                .padding(3)
                .background(Circle().fill(Design.Accent.brand))
            Text("Prepared")
                .font(.system(size: 10, weight: .semibold))
            if vm.canShowGenerated {
                Button(vm.isShowingPrepared ? "Show generated" : "Show prepared") {
                    vm.togglePreparedAnswer()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Design.Accent.brand)
            }
        }
        .help(vm.preparedSource)
    }
}
