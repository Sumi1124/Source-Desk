# Contributing to SourceDesk

Thanks for considering a contribution. This document describes how the project is
built, tested and reviewed, so a change can be merged without a round of questions.

## Getting set up

```bash
git clone https://github.com/<you>/sourcedesk.git
cd sourcedesk
swift build            # no dependencies to resolve
swift run SourceDesk   # launches the app
```

**Xcode 15 or later is required to build.** Apple's Command Line Tools alone cannot
compile SwiftUI's `@Observable` and do not include XCTest, and this project leans on
Swift 5.9 features. The *tests*, however, run with the Command Line Tools (see below).

## Before you open a pull request

```bash
scripts/test.sh                    # must pass
swift build -c release             # must build without warnings you introduced
```

`scripts/test.sh` runs the full verification harness and exits non-zero on failure. If
you are changing retrieval, chunking or providers, also run it a second time to catch
flakiness:

```bash
scripts/test.sh && scripts/test.sh
```

The provider and end-to-end suites use the local loopback interface only. To also
exercise the public internet:

```bash
SOURCEDESK_LIVE_WEB=1 scripts/test.sh
```

Those tests tolerate network failure by design (they assert that a failure is
*actionable*, not that a page exists), so they are safe in CI but not a substitute for
the offline suites.

## The most important rule

**A change to behaviour comes with a change to the harness.**

This project's tests are its specification. A bug fix without a test that fails before
it and passes after it will be asked for a test in review — because the alternative is
that the bug comes back. `Tests/Harness` is not a formality: it caught the real bugs
in this codebase, including foreign-key ordering in the import path, a robot.txt
origin that ignored the port, an overlap buffer that was cleared before it was used,
and a re-added URL that leaked an orphan row each time.

Test names state the behaviour, not the method:

```swift
test("re-adding a URL refreshes the source instead of duplicating it") { ctx in
    // ...
}
```

## Code conventions

- **Comments explain *why*.** The code says what it does. A comment is for the
  non-obvious constraint, the bug being avoided, or the trade-off chosen. `// increment
  the counter` is noise; `// FileHandle's buffering behaves differently on a socket, so
  read with the raw POSIX call` is the reason a future reader does not "simplify" it
  back into a bug.
- **No third-party dependencies.** This is a deliberate constraint (see
  `docs/ARCHITECTURE.md`). If you believe a dependency is justified, open an issue
  first and make the case — the bar is high, because this app holds private documents.
- **The core stays UI-free.** `SourceDeskCore` links no SwiftUI and no AppKit. If you
  need something from AppKit in the core, it probably belongs in the app target.
- **Errors are specific.** Never add a case that just says "something went wrong".
  Every `SourceDeskError` case needs a `errorDescription`, and a `recoverySuggestion`
  when there is a fix the user can apply. If the advice depends on the cause, compute
  it from the payload.
- **Accessibility and appearance.** Use system colours and the `Design` helpers rather
  than hard-coded values; make sure new UI is legible in light and dark mode; give
  icon-only buttons a `.help()` tooltip.
- **Nothing leaves the Mac silently.** If a change causes network traffic, it must be
  visible in the UI (a privacy line, a settings description, or both).

## Adding things

### A new source type

1. Add a case to `SourceKind` with its display name and SF Symbol.
2. Write an extractor returning `ExtractedDocument`, keeping page numbers and heading
   paths.
3. Register it in `DocumentExtractor.kind(for:)` (and provide a `kindFromMagicBytes`
   fallback if the extension is unreliable).
4. Add harness coverage for extraction, including a malformed input.

Chunking, retrieval, citations, the inspector and export need no changes.

### A new AI provider

1. Conform to `AIProvider` in `Sources/SourceDeskCore/AI/`.
2. Register it in `ProviderRegistry.standard`.
3. Add a suite to the harness that runs it against `LocalHTTPServer`: assert the
   request shape (headers, body fields), the streaming framing, at least one error
   status mapping, and the missing-credential path.

Never read a credential from anywhere but `KeychainReading`.

### A new study tool

1. Add a case to `NoteKind` (name + symbol).
2. Add an output contract in `PromptBuilder.outputContract(for:)` — be explicit about
   the exact format, because parsing depends on it.
3. Add a retrieval query in `StudyToolsService.retrievalQuery`.
4. If the output is structured, add a parser and a harness test with a realistic model
   response *and* a malformed one.

### A new search provider

1. Conform to `SearchProvider`, and set `returnsContent` honestly.
2. Add a case to `SearchEngine` with a `detail` string that states the trade-off.
3. Add a parser test with real-shaped markup or JSON.

## Reporting bugs

Include the error message from the app (they are written to be copy-pasteable), the
log excerpt from Settings → Advanced → Show Recent Log, and what you expected. If the
bug involves retrieval quality, the retrieval trace from the inspector is far more
useful than a description — it contains the query, the candidates and the scores.

## Review criteria

A pull request is ready when:

- `scripts/test.sh` passes and new behaviour is covered.
- No new warnings.
- Comments explain the reasoning, not the syntax.
- User-facing strings are specific and actionable.
- Nothing sends data anywhere the privacy documentation does not already describe.
