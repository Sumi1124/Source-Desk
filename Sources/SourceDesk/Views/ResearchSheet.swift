import SwiftUI
import SourceDeskCore

/// Asks for a topic, then hands it to the research pipeline.
///
/// Presented by `RootView` rather than by the command palette: the palette closes as
/// soon as a command runs, which would take the sheet with it.
@MainActor
struct ResearchSheet: View {
    let kind: AppState.ResearchSheetKind
    let onSubmit: (String, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var topic = ""
    @State private var sourceCount = 5
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Design.spacingMedium) {
            HStack {
                Text(kind.title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .help("Close")
            }

            Text(kind.prompt)
                .font(Design.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("e.g. “causes of the industrial decline” or “history of RISC-V”", text: $topic)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { submit() }

            HStack(spacing: Design.spacingSmall) {
                Text("Sources to add")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                Picker("Sources to add", selection: $sourceCount) {
                    ForEach([3, 5, 8, 12], id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .labelsHidden()
                .frame(width: 70)
                Spacer()
            }

            // Say what will happen before it happens: this one sends the topic to a
            // search provider, and each result is downloaded.
            Label("Searches the web with your configured search provider. Nothing is sent to an AI provider until you ask a question.",
                  systemImage: "globe")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Design.spacingSmall) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Research") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(Design.spacingMedium)
        .frame(width: 460)
        .onAppear { focused = true }
    }

    private var trimmed: String {
        topic.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed, sourceCount)
        dismiss()
    }
}

/// Progress for a running research job, with a cancel button. Long operations must be
/// interruptible, and research downloads several pages in a row.
@MainActor
struct ResearchProgressBar: View {
    let progress: AppState.IngestionProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Design.spacingSmall) {
                ProgressView()
                    .controlSize(.small)
                Text(progress.stage)
                    .font(.system(size: 11, weight: .medium))
                Text("\(progress.itemIndex) of \(progress.itemCount)")
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .controlSize(.small)
            }
            Text(progress.title)
                .font(Design.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            ProgressView(value: min(max(progress.overall, 0), 1))
                .progressViewStyle(.linear)
        }
        .padding(Design.spacingSmall)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
