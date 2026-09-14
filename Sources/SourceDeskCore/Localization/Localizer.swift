import Foundation

/// The languages the interface can be shown in.
public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    /// Follow the Mac's own setting.
    case system
    case english = "en"
    case japanese = "ja"

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .english: return "English"
        case .japanese: return "日本語"
        }
    }

    /// The language actually used once `.system` is resolved.
    public var resolved: AppLanguage {
        guard self == .system else { return self }
        // `preferredLanguages` is ordered by user preference and uses BCP-47 tags, so a Mac
        // set to "ja-JP" matches on the "ja" prefix. Matching the prefix rather than the whole
        // tag is what makes a regional variant work.
        for tag in Locale.preferredLanguages {
            let code = tag.split(separator: "-").first.map(String.init) ?? tag
            if code == "ja" { return .japanese }
            if code == "en" { return .english }
        }
        return .english
    }
}

/// Looks up interface text in the selected language.
///
/// Design notes, because the choices here are deliberate:
///
/// - **The English string is the key.** `L("Add Files…")` looks up "Add Files…" in the
///   Japanese table and falls back to the argument when absent. There is no separate key
///   namespace to keep in sync, and an untranslated string degrades to correct English
///   rather than to a raw key like `sources.addFiles.title`.
/// - **The table is compiled in, not loaded from disk.** The app is assembled by a shell
///   script that copies a bare executable into the bundle, so a SwiftPM resource bundle
///   would not be there at runtime. Compiling the table in makes the app and the test
///   harness behave identically, with no path lookup that can fail.
/// - **Switching is instant.** The table is swapped in memory, so the UI can change language
///   without a relaunch. The root view is re-identified on language change to force a redraw.
public final class Localizer: @unchecked Sendable {

    public static let shared = Localizer()

    private let lock = NSLock()
    private var language: AppLanguage = .english

    private init() {
        language = AppLanguage.system.resolved
    }

    /// The language currently in use (never `.system`).
    public var current: AppLanguage {
        lock.lock(); defer { lock.unlock() }
        return language
    }

    /// Switches the interface language immediately.
    public func setLanguage(_ new: AppLanguage) {
        lock.lock()
        language = new.resolved
        lock.unlock()
    }

    /// Resolves `english` in the current language, falling back to `english` itself.
    public func text(_ english: String) -> String {
        let language = self.language
        guard language != .english else { return english }
        return Self.table(for: language)[english] ?? english
    }

    /// Resolves a string containing values.
    ///
    /// The English form is written with `%@` placeholders so the key stays stable and the
    /// translator can move the values where the target grammar wants them — which matters,
    /// because Japanese places counters and particles differently from English.
    public func text(_ english: String, _ values: [String]) -> String {
        let resolved = text(english)
        guard !values.isEmpty else { return resolved }
        var result = resolved
        for value in values {
            guard let range = result.range(of: "%@") else { break }
            result.replaceSubrange(range, with: value)
        }
        return result
    }

    /// True when a translation exists — used by the tests and by the coverage report.
    public func hasTranslation(for english: String) -> Bool {
        Self.table(for: current)[english] != nil
    }

    public static func table(for language: AppLanguage) -> [String: String] {
        switch language {
        case .japanese: return JapaneseStrings.table
        case .english, .system: return [:]
        }
    }
}

/// Shorthand for the current language's text.
///
/// A free function rather than a method so call sites read as prose and can be applied
/// mechanically: `Text(L("Add Files…"))`.
public func L(_ english: String) -> String {
    Localizer.shared.text(english)
}

/// Shorthand for a string containing values, e.g. `L("Add %@ files", "3")`.
public func L(_ english: String, _ values: String...) -> String {
    Localizer.shared.text(english, values)
}
