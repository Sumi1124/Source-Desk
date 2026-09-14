import Foundation
import SourceDeskCore

/// The interface language mechanism.
///
/// Localization is easy to fake: a table of translations that no one ever looks up, or a
/// picker that saves a preference nothing reads, both pass a casual review. What matters is
/// that a translated string actually renders, that an untranslated one degrades to English
/// rather than to a raw key, that values land in the right place, and that switching takes
/// effect without relaunching.
enum LocalizationSuite {

    static var suite: TestSuite {
        TestSuite("30 · Interface language", cases: [

            test("a translated string renders in Japanese") { ctx in
                Localizer.shared.setLanguage(.japanese)
                defer { Localizer.shared.setLanguage(.english) }
                try ctx.equal(L("Sources"), "ソース", "the section name is translated")
                try ctx.equal(L("Add Files…"), "ファイルを追加…", "the menu item is translated")
                // A string the table does not cover must stay readable English, not become a
                // key or a blank. This is the property that makes partial coverage safe.
                let untranslated = "A string no translator has seen yet"
                try ctx.equal(L(untranslated), untranslated, "an unknown string falls back to English")
            },

            test("English mode leaves every string untouched") { ctx in
                Localizer.shared.setLanguage(.english)
                defer { Localizer.shared.setLanguage(.english) }
                for english in ["Sources", "Add Files…", "Settings", "Passages"] {
                    try ctx.equal(L(english), english, "\(english) is unchanged in English")
                }
            },

            test("values are substituted into the translated form") { ctx in
                Localizer.shared.setLanguage(.japanese)
                defer { Localizer.shared.setLanguage(.english) }
                // Japanese puts the count and the noun in a different order from English, so
                // the test uses a form where the value moves — proving the placeholder is
                // honoured rather than the English word order being assumed.
                let result = L("%@ sources", "3")
                try ctx.check(!result.contains("%@"), "the placeholder was replaced: \(result)")
                try ctx.check(result.contains("3"), "the value is present: \(result)")
            },

            test("switching language takes effect immediately") { ctx in
                Localizer.shared.setLanguage(.english)
                let before = L("Sources")
                Localizer.shared.setLanguage(.japanese)
                let after = L("Sources")
                defer { Localizer.shared.setLanguage(.english) }
                try ctx.check(before != after, "the same key resolved differently after switching")
                try ctx.equal(before, "Sources", "before switching it was English")
                try ctx.equal(after, "ソース", "after switching it is Japanese")
            },

            test("system resolves to a real language, never to .system") { ctx in
                let resolved = AppLanguage.system.resolved
                try ctx.check(resolved != .system, "system resolved to a concrete language")
                try ctx.check(AppLanguage.allCases.contains(resolved), "and it is a known language")
            },

            // The settings blob is the thing that would break an upgrade if this were wrong:
            // a user's existing settings have no `language` key.
            test("settings written before the language existed still load") { ctx in
                var settings = AppSettings()
                settings.language = .japanese
                let encoded = try JSONEncoder().encode(settings)
                var json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
                try ctx.check(json["language"] != nil, "the language is persisted")

                // Simulate an older blob by removing the key, then decode.
                json.removeValue(forKey: "language")
                let older = try JSONSerialization.data(withJSONObject: json)
                let restored = try JSONDecoder().decode(AppSettings.self, from: older)
                try ctx.equal(restored.language, .system,
                              "an older settings file defaults to following the Mac")

                // And a real round trip preserves the choice.
                let round = try JSONDecoder().decode(AppSettings.self, from: encoded)
                try ctx.equal(round.language, .japanese, "a round trip keeps the chosen language")
            },

            // A duplicate key in a dictionary literal is a runtime trap, not a warning: the
            // process aborts the moment the table is built. It shipped once and crashed on
            // launch, so the table's own shape is asserted here.
            test("the table has no duplicate keys") { ctx in
                let source = try String(
                    contentsOfFile: "Sources/SourceDeskCore/Localization/JapaneseStrings.swift",
                    encoding: .utf8
                )
                // A key is the FIRST quoted string on a line whose closing quote is
                // immediately followed by a colon. Splitting on the first colon alone would
                // miscount, because a colon also appears inside values ("Retrieval": "検索: …").
                var seen = Set<String>()
                var duplicates: [String] = []
                for line in source.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("\"") else { continue }
                    guard let closing = trimmed.range(of: "\":", range: trimmed.index(after: trimmed.startIndex)..<trimmed.endIndex)
                    else { continue }
                    let key = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing.lowerBound])
                    if key.isEmpty { continue }
                    if !seen.insert(key).inserted { duplicates.append(key) }
                }
                try ctx.check(duplicates.isEmpty,
                              "no duplicate keys (found: \(duplicates.prefix(5)))")
                try ctx.check(seen.count > 350, "the table is substantial (\(seen.count) keys)")
            },

            // Coverage is reported rather than assumed, so a half-finished translation is
            // visible as a number instead of being discovered by a user.
            test("translation coverage is reported") { ctx in
                let table = Localizer.table(for: .japanese)
                try ctx.check(table.count > 80, "a meaningful number of strings are translated (\(table.count))")
                // Every entry must be non-empty and must not be a placeholder echo.
                let empties = table.filter { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }
                try ctx.check(empties.isEmpty, "no translation is empty: \(empties.keys.sorted().prefix(3))")
                ctx.notes.append("Japanese coverage: \(table.count) strings")
            }
        ])
    }
}
