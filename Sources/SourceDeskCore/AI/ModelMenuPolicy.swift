import Foundation

/// How the model picker should present each provider.
///
/// This lives in the core rather than in the view because it is the part that was
/// wrong, and because "can I see this model?" and "can I run this model?" turned out
/// to be different questions that the UI had collapsed into one. Keeping the policy
/// here makes it verifiable without a UI.
///
/// The specific bug this fixes: `AppState.loadModels` used to return early whenever a
/// provider was not configured, so Ollama's hosted catalogue — which is readable
/// without a key — rendered as an empty menu section. The user saw "Ollama Cloud" with
/// no models under it and could not tell whether the feature existed or was broken.
public enum ModelMenuPolicy {

    /// A model row the user can choose.
    public struct Row: Sendable, Equatable, Identifiable {
        public var id: String { model.name }
        public let model: ModelDescriptor
        /// Whether choosing it will actually produce an answer right now.
        public let isUsable: Bool
    }

    /// One provider's section in the menu.
    public struct Section: Sendable, Equatable, Identifiable {
        public var id: String { providerID }
        public let providerID: String
        public let displayName: String
        /// The reason a provider cannot be used, shown above its models.
        public let statusLine: String?
        /// Shown in place of rows when there are none.
        public let emptyLine: String?
        public let rows: [Row]

        /// True when the section contains something the user could actually run.
        public var hasUsableModel: Bool { rows.contains(where: \.isUsable) }
    }

    /// Builds a section for one provider.
    ///
    /// - Parameters:
    ///   - models: whatever the provider could list. Listing is attempted even when the
    ///     provider is not configured, because several providers can list without a
    ///     credential and seeing the choice is how a user learns what to configure.
    ///   - availability: why the provider can or cannot answer right now.
    ///   - hasBeenProbed: false while discovery is still in flight, which changes the
    ///     empty text from "checking" to a definite answer.
    public static func section(
        providerID: String,
        displayName: String,
        models: [ModelDescriptor],
        availability: ProviderAvailability?,
        hasBeenProbed: Bool
    ) -> Section {
        let chatModels = models.filter { !$0.supportsEmbeddings }
        let usable = availability?.isReady ?? false
        let reason = availability?.reason

        let rows = chatModels.map { Row(model: $0, isUsable: usable) }

        // A not-ready provider already shows its reason on the status line, so the empty
        // line must not repeat it.
        let emptyLine: String?
        if !rows.isEmpty {
            emptyLine = nil
        } else if availability?.isReady == true || availability == nil {
            emptyLine = hasBeenProbed ? "No models found" : "Checking…"
        } else {
            emptyLine = "No models listed"
        }

        return Section(
            providerID: providerID,
            displayName: displayName,
            statusLine: reason,
            emptyLine: emptyLine,
            rows: rows
        )
    }
}
