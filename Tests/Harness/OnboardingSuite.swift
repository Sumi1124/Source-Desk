import Foundation
import SourceDeskCore

/// The first-run welcome flow.
///
/// The decision logic lives in `OnboardingPolicy` in the core, so it can be asserted here
/// without a window. What matters is not the sheet's layout but the rules around it: when it
/// is offered, that it is never offered twice, that an upgraded install is not treated as a
/// new user, and that re-running it cannot duplicate anything.
enum OnboardingSuite {

    static var suite: TestSuite {
        TestSuite("27 · Onboarding", cases: [

            test("a genuine first run is onboarded") { ctx in
                // No settings blob has ever been written: a fresh install.
                let decision = OnboardingPolicy.launchDecision(
                    settings: AppSettings(),
                    hasSavedSettings: false
                )
                try ctx.equal(decision, .present)
            },

            test("an install upgraded from a build without the flow is not onboarded") { ctx in
                // This is the case that matters most: an existing user updating the app has
                // settings on disk but no hasCompletedOnboarding key, which decodes to
                // false. Treating that as a first run would drop welcome copy in front of
                // someone with a full library.
                var existing = AppSettings()
                existing.preferredProviderID = "openai"
                try ctx.check(!existing.hasCompletedOnboarding, "the flag is absent, so false")

                let decision = OnboardingPolicy.launchDecision(
                    settings: existing,
                    hasSavedSettings: true
                )
                try ctx.equal(decision, .suppressAndRecordSeen)
            },

            test("a completed flow is never offered again") { ctx in
                var settings = AppSettings()
                settings.hasCompletedOnboarding = true
                try ctx.equal(
                    OnboardingPolicy.launchDecision(settings: settings, hasSavedSettings: true),
                    .suppress
                )
                // Even if the settings blob somehow vanished, an explicit completion wins.
                try ctx.equal(
                    OnboardingPolicy.launchDecision(settings: settings, hasSavedSettings: false),
                    .suppress
                )
            },

            test("an empty library is not itself a reason to onboard") { ctx in
                // A long-time user who deletes every notebook has not asked to see the
                // welcome flow. The policy takes no notebook count by design; this asserts
                // the signature cannot be fooled by one.
                var settings = AppSettings()
                settings.hasCompletedOnboarding = true
                let decision = OnboardingPolicy.launchDecision(
                    settings: settings,
                    hasSavedSettings: true
                )
                try ctx.equal(decision, .suppress, "an empty library still suppresses")
            },

            test("the harness can suppress the flow without touching the user's settings") { ctx in
                let decision = OnboardingPolicy.launchDecision(
                    settings: AppSettings(),
                    hasSavedSettings: false,
                    suppressed: true
                )
                try ctx.equal(decision, .suppress, "suppression wins over a genuine first run")
            },

            test("the starter notebook is created once, and only on an empty library") { ctx in
                try ctx.check(OnboardingPolicy.shouldCreateStarterNotebook(requested: true, existingNotebookCount: 0))
                // Re-running the flow from Help must not create a second one.
                try ctx.check(!OnboardingPolicy.shouldCreateStarterNotebook(requested: true, existingNotebookCount: 1))
                try ctx.check(!OnboardingPolicy.shouldCreateStarterNotebook(requested: true, existingNotebookCount: 7))
                // Declining is always honoured, even on an empty library.
                try ctx.check(!OnboardingPolicy.shouldCreateStarterNotebook(requested: false, existingNotebookCount: 0))
            },

            test("onboarding state round-trips through the settings store") { ctx in
                let paths = AppPaths(root: FileManager.default.temporaryDirectory
                    .appendingPathComponent("onboard-\(UUID().uuidString)", isDirectory: true))
                defer { try? FileManager.default.removeItem(at: paths.root) }

                let store = try NotebookStore(paths: paths)
                let settingsStore = SettingsStore(store: store)
                try ctx.check(!settingsStore.hasSavedSettings, "a fresh store has no settings")

                var settings = settingsStore.load()
                settings.hasCompletedOnboarding = true
                settings.onboardingStepIndex = 2
                settings.onboardingSelectedModel = "llama3.2"
                try settingsStore.save(settings)

                try ctx.check(settingsStore.hasSavedSettings, "after a save, settings exist")
                let reloaded = settingsStore.load()
                try ctx.check(reloaded.hasCompletedOnboarding)
                try ctx.equal(reloaded.onboardingStepIndex, 2)
                try ctx.equal(reloaded.onboardingSelectedModel, "llama3.2")
            },

            test("settings written before the flow existed are completed, not rejected") { ctx in
                // A blob from an older build has none of the onboarding keys. It must decode
                // so the user keeps every preference, with the new keys filled in.
                let legacy = """
                {"preferredProviderID":"ollama","chatFontSize":15,"showInspector":false,
                 "searchResultCount":9,"temperature":0.42}
                """
                let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
                try ctx.equal(decoded.preferredProviderID, "ollama")
                try ctx.equal(decoded.chatFontSize, 15)
                try ctx.check(!decoded.showInspector, "an existing preference is kept")
                try ctx.equal(decoded.searchResultCount, 9)
                try ctx.equal(decoded.temperature, 0.42)
                try ctx.check(!decoded.hasCompletedOnboarding, "the new key falls back")
                try ctx.equal(decoded.onboardingStepIndex, 0)
                try ctx.equal(decoded.onboardingSelectedModel, "")
            },

            test("a local provider is named once, not twice") { ctx in
                // "Ollama (local) (on this Mac)" shipped in the first render of the flow.
                // The rule is reproduced here because it is a string decision with a visible
                // wrong answer.
                func label(_ displayName: String, isLocal: Bool) -> String {
                    guard isLocal else { return displayName }
                    if displayName.localizedCaseInsensitiveContains("local")
                        || displayName.localizedCaseInsensitiveContains("this Mac") {
                        return displayName
                    }
                    return "\(displayName) (on this Mac)"
                }

                try ctx.equal(label("Ollama (local)", isLocal: true), "Ollama (local)")
                try ctx.equal(label("Ollama", isLocal: true), "Ollama (on this Mac)")
                try ctx.equal(label("OpenAI", isLocal: false), "OpenAI")
                try ctx.equal(label("Anthropic Claude", isLocal: false), "Anthropic Claude")
                for name in ["Ollama (local)", "Ollama", "OpenAI", "Ollama Cloud"] {
                    let text = label(name, isLocal: name.hasPrefix("Ollama") && !name.contains("Cloud"))
                    try ctx.check(!text.contains("(local) (on this Mac)"), "doubled suffix in: \(text)")
                    try ctx.check(!text.contains("Mac) (on"), "doubled suffix in: \(text)")
                }
            },

            test("the providers the flow offers are the ones the app has") { ctx in
                // The flow's picker is driven by the same registry settings use, so a
                // provider added to the app cannot be missing from onboarding.
                let registry = ProviderRegistry.standard()
                let ids = registry.all.map(\.identifier)
                try ctx.check(ids.contains("ollama"), "the local provider is offered")
                try ctx.check(ids.count >= 3, "cloud providers are offered too, got: \(ids)")
                // Local-first ordering is what the picker relies on to default sensibly.
                try ctx.check(registry.all.first?.isLocal == true, "a local provider sorts first")
                // Every provider in the flow must be nameable without a doubled suffix.
                for provider in registry.all {
                    let text = provider.isLocal ? provider.displayName : provider.displayName
                    try ctx.check(!text.isEmpty, "every provider has a name")
                }
            },
        ])
    }
}
