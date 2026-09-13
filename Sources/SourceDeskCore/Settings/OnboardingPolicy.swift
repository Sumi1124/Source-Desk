import Foundation

/// Decides whether the welcome flow should be offered, and what it should record.
///
/// This is policy, not presentation, so it lives in the core where it can be tested without
/// a window. It was extracted from `AppState` for exactly that reason: the interesting
/// question — "should this user be onboarded?" — is a pure function of stored settings and
/// library state, and the first version of it was buried in a view model where the harness
/// could not reach it.
public enum OnboardingPolicy {

    /// What the app should do about the welcome flow at launch.
    public enum LaunchDecision: Equatable {
        /// Show the flow.
        case present
        /// Do not show it, and record that this user has seen the app before.
        case suppressAndRecordSeen
        /// Do not show it; nothing to record.
        case suppress
    }

    /// The launch decision for a given store and settings.
    ///
    /// The test is "has a settings blob ever been written", deliberately not "is the library
    /// empty". A user who deletes every notebook has not asked to be onboarded again, and
    /// inferring first-run from an empty library would show them marketing copy instead of
    /// their (empty) workspace.
    ///
    /// - Parameters:
    ///   - settings: the settings as loaded from disk.
    ///   - hasSavedSettings: whether the settings blob exists at all.
    ///   - suppressed: true when the harness or screenshot pass is driving the app and must
    ///     not be interrupted by a sheet.
    public static func launchDecision(
        settings: AppSettings,
        hasSavedSettings: Bool,
        suppressed: Bool = false
    ) -> LaunchDecision {
        if suppressed { return .suppress }
        if settings.hasCompletedOnboarding { return .suppress }
        // Settings exist but the flag is unset: an install upgraded from a build that had no
        // welcome flow. Treat as seen, so an existing user gets their workspace.
        if hasSavedSettings { return .suppressAndRecordSeen }
        return .present
    }

    /// Whether finishing the flow should create a notebook.
    ///
    /// Requested by the user *and* only when the library is empty, so a re-run from the Help
    /// menu cannot pile up duplicate "My Research" notebooks.
    public static func shouldCreateStarterNotebook(
        requested: Bool,
        existingNotebookCount: Int
    ) -> Bool {
        requested && existingNotebookCount == 0
    }

    /// The title of the notebook the flow creates, if it creates one.
    public static let starterNotebookTitle = "My Research"
    public static let starterNotebookSummary = "Sources, questions and notes."
}
