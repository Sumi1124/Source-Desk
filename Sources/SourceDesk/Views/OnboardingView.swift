import SwiftUI
import SourceDeskCore

/// The first-run welcome flow.
///
/// Four steps, each answering a question a new user actually has before they can use the
/// app usefully:
///
///  1. What is this, and where does my data go?
///  2. Which model should I talk to? (detects Ollama live rather than assuming)
///  3. Here is a notebook, add something to it.
///  4. What just happened, and what next?
///
/// Deliberately skippable at every point, and deliberately not a carousel of feature
/// marketing — a user who dismisses it should still land somewhere sensible. Re-openable
/// from the Help menu, so it doubles as a refresher rather than being a one-shot gate.
@MainActor
struct OnboardingView: View {

    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// Called once the flow finishes, with whatever the user chose.
    let onFinish: (Outcome) -> Void

    struct Outcome {
        var createStarterNotebook: Bool
        var selectedModel: String?
        var selectedProviderID: String?
    }

    @State private var step = 0
    @State private var providerID = "ollama"
    @State private var model = ""
    @State private var models: [String] = []
    @State private var modelState: ModelState = .idle
    @State private var createNotebook = true
    /// Read once on appear: the endpoint is user-editable and we do not want the copy
    /// changing under the user mid-flow if they edit settings in another window.
    @State private var ollamaEndpoint = "http://127.0.0.1:11434"

    private enum ModelState: Equatable {
        case idle, checking, ready(Int), unreachable(String)
    }

    private var steps: [Step] { Step.allCases }

    enum Step: Int, CaseIterable {
        case welcome, model, firstSource, done

        var title: String {
            switch self {
            case .welcome:     return L("Welcome to SourceDesk")
            case .model:       return L("Choose a model")
            case .firstSource: return L("Add your first source")
            case .done:        return L("You are ready")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .frame(maxWidth: Design.onboardingContentWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, Design.spacingLarge)
                    .padding(.vertical, Design.spacingLarge)
            }
            Divider()
            footer
        }
        .frame(width: Design.onboardingWidth, height: Design.onboardingHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            ollamaEndpoint = app.settings.ollamaEndpoint
            providerID = app.settings.preferredProviderID
            model = app.settings.modelSelection[providerID] ?? ""
            step = min(max(app.settings.onboardingStepIndex, 0), steps.count - 1)
            if steps[step] == .model { await checkModels() }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: Design.spacingSmall) {
            Image(systemName: "book.closed")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text(steps[step].title)
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            // Step dots rather than a progress bar: there are four steps and the user can
            // go back, so "where am I" matters more than "how much is left".
            HStack(spacing: 5) {
                ForEach(steps, id: \.rawValue) { s in
                    Circle()
                        .fill(s.rawValue <= step ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(step + 1) of \(steps.count)")
        }
        .padding(.horizontal, Design.spacingLarge)
        .padding(.vertical, Design.spacingMedium)
    }

    @ViewBuilder
    private var content: some View {
        switch steps[step] {
        case .welcome:     welcomeStep
        case .model:       modelStep
        case .firstSource: firstSourceStep
        case .done:        doneStep
        }
    }

    private var footer: some View {
        HStack(spacing: Design.spacingSmall) {
            // Skipping is always available and never punished: the app is fully usable
            // without the flow, and a user who wants to explore first should not be blocked.
            Button(L("Skip")) { finish(createNotebook: false) }
                .buttonStyle(.link)
                .help("Dismiss the welcome flow. You can reopen it from Help.")

            Spacer()

            if step > 0 {
                Button(L("Back")) { go(to: step - 1) }
            }
            Button(primaryTitle) { advance() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, Design.spacingLarge)
        .padding(.vertical, Design.spacingMedium)
    }

    private var primaryTitle: String {
        switch steps[step] {
        case .welcome:     return L("Get started")
        case .model:       return L("Continue")
        case .firstSource: return createNotebook ? "Create notebook" : "Continue"
        case .done:        return L("Open SourceDesk")
        }
    }

    // MARK: Steps

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: Design.spacingLarge) {
            Text(L("A research notebook that keeps your sources on your Mac."))
                .font(.system(size: 15))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: Design.spacingMedium) {
                bullet(
                    "doc.text.magnifyingglass",
                    "Add sources",
                    "Websites, PDFs, DOCX, EPUB, Markdown, HTML or pasted text. There is no cap on how many — only your disk."
                )
                bullet(
                    "text.bubble",
                    "Ask questions",
                    "Answers are drawn from your sources and cite the passages they used. You can open any citation to read it in context."
                )
                bullet(
                    "lock",
                    "Nothing leaves the Mac by itself",
                    "Notebooks, sources, extracted text, embeddings and conversations live in one local folder. A cloud model is only contacted if you deliberately choose one."
                )
            }

            // The honest statement of the offline/online split, on the first screen, where
            // a privacy-minded user will look for it.
            privacyNote
        }
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: Design.spacingLarge) {
            Text(L("SourceDesk can use a model on this Mac, or a cloud provider you connect."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: Design.spacingSmall) {
                Text(L("Provider"))
                    .font(Design.caption)
                    .foregroundStyle(.secondary)

                Picker(L("Provider"), selection: $providerID) {
                    ForEach(app.providers.all, id: \.identifier) { provider in
                        Text(providerLabel(provider)).tag(provider.identifier)
                    }
                }
                .labelsHidden()
                .onChange(of: providerID) { _, newValue in
                    model = app.settings.modelSelection[newValue] ?? ""
                    models = []
                    modelState = .idle
                    Task { await checkModels() }
                }
            }

            modelStatus

            // Offered only when a check found nothing: after the user starts Ollama or
            // pulls a model, re-running the check is the obvious next step, and the status
            // text refers to it by name.
            if showRecheck {
                Button(L("Check again")) {
                    Task { await checkModels() }
                }
                .controlSize(.small)
            }

            if !models.isEmpty {
                VStack(alignment: .leading, spacing: Design.spacingSmall) {
                    Text(L("Model"))
                        .font(Design.caption)
                        .foregroundStyle(.secondary)
                    Picker(L("Model"), selection: $model) {
                        Text(L("Choose a model")).tag("")
                        ForEach(models, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                }
            }

            localVsCloudNote
        }
    }

    @ViewBuilder
    private var modelStatus: some View {
        switch modelState {
        case .idle:
            EmptyView()

        case .checking:
            HStack(spacing: Design.spacingSmall) {
                ProgressView().controlSize(.small)
                Text(L("Looking for models…"))
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
            }

        case .ready(let count):
            statusLine(
                icon: count > 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                tint: count > 0 ? .green : .orange,
                text: count > 0
                    ? "Found \(Format.count(count, "model")) on \(isLocalProvider ? "this Mac" : "this provider")."
                    : "This provider is running but has no models installed yet."
            )

        case .unreachable(let message):
            statusLine(icon: "exclamationmark.triangle.fill", tint: .orange, text: message)
        }
    }

    private var firstSourceStep: some View {
        VStack(alignment: .leading, spacing: Design.spacingLarge) {
            Text(createNotebook
                 ? "Create a notebook to hold your sources, questions and notes."
                 : "You can start without a notebook and create one whenever you like.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Toggle(isOn: $createNotebook) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Create my first notebook now"))
                    Text(L("A notebook groups sources with the questions and notes about them."))
                        .font(Design.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            if createNotebook {
                VStack(alignment: .leading, spacing: Design.spacingSmall) {
                    Text(L("Ways to add a source once you are in:"))
                        .font(Design.caption)
                        .foregroundStyle(.secondary)
                    bullet("globe", "Paste a website address", "SourceDesk fetches the page and extracts the readable article text.")
                    bullet("doc.badge.plus", "Drop in files", "Drag PDFs or documents onto the window, or use Add Sources.")
                    bullet("wand.and.stars", "Search a topic", "Describe what you are researching and SourceDesk finds pages, shows you the picks, and adds the ones you approve.")
                }
            }
        }
    }

    private var doneStep: some View {
        VStack(alignment: .leading, spacing: Design.spacingLarge) {
            statusLine(
                icon: "checkmark.circle.fill",
                tint: .green,
                text: completionSummary
            )

            VStack(alignment: .leading, spacing: Design.spacingMedium) {
                Text(L("A few things worth knowing:"))
                    .font(.system(size: 13, weight: .medium))
                bullet("command", "Press ⌘K", "Opens the command palette — jump to a notebook, add a source, or run a generator.")
                bullet("questionmark.circle", "Citations are checkable", "Click a citation in an answer to open the exact passage it came from.")
                bullet("wifi.slash", "Offline works", "With a local model installed, you can read and ask questions with no connection. The toolbar shows the current state.")
            }
        }
    }

    private var completionSummary: String {
        var parts: [String] = []
        if !model.isEmpty { parts.append("Using \(model).") }
        parts.append(createNotebook ? "Your notebook is ready." : "Your library is ready.")
        return parts.joined(separator: " ")
    }

    // MARK: Pieces

    private func bullet(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Design.spacingMedium) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusLine(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: Design.spacingSmall) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.system(size: 12))
            Text(text)
                .font(Design.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: Design.spacingSmall) {
            Divider()
            HStack(alignment: .top, spacing: Design.spacingSmall) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Online: web search, downloading pages, and any cloud model you connect."))
                    Text(L("Offline: your sources, questions, notes and local models."))
                }
                .font(Design.caption)
                .foregroundStyle(.secondary)
            }
            Text("Your library lives at \(app.settings.storageRootPath).")
                .font(Design.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    private var localVsCloudNote: some View {
        VStack(alignment: .leading, spacing: Design.spacingSmall) {
            Divider()
            if isLocalProvider {
                Text(L("Ollama runs models on this Mac, so questions and sources stay on it. It needs at least one model pulled, and enough memory for the model you pick."))
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("This is a cloud provider. When you ask a question, the passages it uses are sent to that provider so it can answer. SourceDesk asks for confirmation the first time you do this for each notebook."))
                    .font(Design.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// True when the last check came back empty, so re-checking is worth offering.
    private var showRecheck: Bool {
        if case .ready(0) = modelState { return true }
        if case .unreachable = modelState { return true }
        return false
    }

    private var isLocalProvider: Bool {
        app.providers.provider(id: providerID)?.isLocal ?? false
    }

    /// Names the provider without repeating itself.
    ///
    /// Local providers already carry "(local)" in their display name, so appending
    /// "(on this Mac)" produced "Ollama (local) (on this Mac)". The suffix is added only
    /// when the name does not already say where the model runs.
    private func providerLabel(_ provider: any AIProvider) -> String {
        guard provider.isLocal else { return provider.displayName }
        let name = provider.displayName
        if name.localizedCaseInsensitiveContains("local") || name.localizedCaseInsensitiveContains("this Mac") {
            return name
        }
        return "\(name) (on this Mac)"
    }

    // MARK: Behaviour

    private func go(to index: Int) {
        // Remember where the user got to, so closing the window mid-flow and reopening it
        // from Help resumes rather than starting over.
        app.updateSettings { $0.onboardingStepIndex = index }
        step = index
        if steps[step] == .model { Task { await checkModels() } }
    }

    private func advance() {
        switch steps[step] {
        case .model:
            if !model.isEmpty {
                app.updateSettings {
                    $0.onboardingSelectedModel = model
                    $0.modelSelection[providerID] = model
                    $0.preferredProviderID = providerID
                }
            }
            go(to: step + 1)
        case .done:
            finish(createNotebook: createNotebook)
        default:
            go(to: step + 1)
        }
    }

    private func finish(createNotebook: Bool) {
        onFinish(Outcome(
            createStarterNotebook: createNotebook,
            selectedModel: model.isEmpty ? nil : model,
            selectedProviderID: model.isEmpty ? nil : providerID
        ))
        dismiss()
    }

    /// Asks the provider what it actually has, rather than assuming a pulled model exists.
    /// A new user with no models is the common case and the flow must say so plainly
    /// instead of failing later at the first question.
    private func checkModels() async {
        modelState = .checking
        let id = providerID
        await app.loadModels(for: id, force: true)
        guard id == providerID else { return }   // the user switched while we were asking
        let list = (app.availableModels[id] ?? []).map(\.name)
        models = list
        if !list.isEmpty, model.isEmpty { model = list[0] }
        if list.isEmpty {
            modelState = isLocalProvider
                ? .unreachable(ollamaHint)
                : .ready(0)
        } else {
            modelState = .ready(list.count)
        }
    }

    /// A concrete, copy-pasteable next step, naming the actual configured endpoint so a
    /// user pointing at a non-default port is not told to check the default one.
    private var ollamaHint: String {
        """
        No models found at \(ollamaEndpoint). Install from ollama.com, then run \
        `ollama pull llama3.2` in Terminal. If Ollama is not running, start it and choose \
        Check again. You can also continue and pick a model later in Settings.
        """
    }
}
