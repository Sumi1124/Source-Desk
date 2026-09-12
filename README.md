<img src="docs/icon.png" width="96" align="right" alt="SourceDesk icon">

# SourceDesk

A local-first AI research notebook for macOS. Collect sources — websites, PDFs,
documents, pasted text — keep everything on your Mac, and ask questions that are
answered from your material **with citations you can inspect**.

SourceDesk is an independent project. It is inspired by the general idea of
document-grounded AI assistants, but contains no code, assets, prompts or branding
from Google NotebookLM or any other product.

## Download

**[Download the latest SourceDesk.dmg](https://github.com/Sumi1124/Source-Desk/releases/latest)**

Open the disk image, drag **SourceDesk** into your Applications folder, and launch it.

> **The first launch needs a right-click → Open.** The app is not notarised by Apple —
> that requires a paid Developer ID, which this project does not have — so macOS shows a
> "cannot be verified" warning the first time. Right-click (or Control-click) the app,
> choose **Open**, and confirm. You only do this once. Alternatively:
> `xattr -d com.apple.quarantine /Applications/SourceDesk.app`

Requires macOS 14 or later. Universal binaries are not built yet, so the release image
targets Apple Silicon; Intel Macs should build from source (below).

![SourceDesk](docs/screenshots/01-research.png)

---

## What it does

- **Unlimited sources.** Add as many websites, PDFs, DOCX, RTF, EPUB, Markdown,
  HTML or pasted-text sources as your disk allows. There are no product-imposed
  caps on source count, notebooks or total size — only the limits of your machine,
  your storage, and the providers you choose to use.
- **Answers grounded in your sources, with citations.** Every answer cites the
  passages it used. Clicking a citation opens the source, the page, the section and
  the excerpt behind it. Citation markers that do not resolve to a retrieved passage
  are removed from the answer rather than shown.
- **Local-first, and honest about it.** Notebooks, sources, extracted text, chunks,
  vectors, conversations, notes and settings all live in one folder on your Mac.
  Nothing is uploaded by SourceDesk itself. Choose a local model and nothing leaves
  the machine at all.
- **Local, hosted or cloud models.** Ollama on your Mac, Ollama's hosted API at
  ollama.com (for models too large to run locally), OpenAI, or Anthropic Claude.
  Switchable per conversation, with an explicit per-notebook confirmation before any
  source text leaves the Mac.
- **Optional web search.** Notebook only, notebook + web, or web only — with web
  results always labelled separately from your sources.
- **Offline mode.** Read sources, search locally, chat with a local model and
  generate notes with no network connection.
- **Study tools.** Eleven generators: summary, key points, timeline, FAQ, quiz,
  flashcards, study guide, outline, quotations, source comparison and briefing. Quiz
  and flashcard output is structured, so the app can run them interactively.
- **Open export format.** Notebooks export to a plain `.nbk` zip you can read with
  `unzip` and any text editor.

## Screenshots

| | |
|---|---|
| ![Sources](docs/screenshots/02-sources.png) **Source management** — status, size, passages | ![Source inspector](docs/screenshots/03-source-inspector.png) **Inspector** — provenance, extracted text, passages |
| ![Study tools](docs/screenshots/04-study-tools.png) **Study tools** — eleven generators | ![Notes](docs/screenshots/05-notes-flashcards.png) **Notes** — flashcards and quizzes you can run |
| ![Search](docs/screenshots/06-web-search.png) **Web search** — results you can add as sources | ![Command palette](docs/screenshots/08-command-palette.png) **Command palette** — ⌘K across everything |
| ![Providers](docs/screenshots/07-settings-providers.png) **Providers** — local first, cloud optional | ![Privacy](docs/screenshots/07c-settings-privacy.png) **Privacy** — what leaves the Mac, stated plainly |

These are rendered from the app's own views by `SourceDesk --render-screenshots`;
regenerate them with `scripts/screenshots.sh`. They cannot drift from the interface,
because they *are* the interface.

## Requirements

- macOS 14 Sonoma or later
- **Xcode 15 or later to build** (the SwiftData/Observation macro plugins ship with
  Xcode, not the Command Line Tools — see [Building](#building))
- Optional: [Ollama](https://ollama.com) for local models
- Optional: API keys for OpenAI, Anthropic, and/or a search provider

## Install

```bash
scripts/build_app.sh release     # assembles build/SourceDesk.app
open build/SourceDesk.app
```

Prebuilt binaries are attached to every run of **Actions → Build and test** on GitHub
(see `.github/workflows/build.yml`). Move `SourceDesk.app` to `/Applications`, then
**right-click → Open** the first time: the app is unsigned, so macOS asks once.

## Building

```bash
git clone https://github.com/Sumi1124/Source-Desk.git
cd Source-Desk
swift build -c release
open .build/release/SourceDesk
```

`scripts/build_app.sh` wraps the built binary in a proper `.app` bundle (Info.plist,
icon, ad-hoc signature) so it behaves like a normal Mac application. The icon is
generated by `scripts/generate_icon.py` using only the Python standard library.

### Making a release

```bash
scripts/build_app.sh release     # build/SourceDesk.app
scripts/build_dmg.sh 1.0.0       # build/SourceDesk-1.0.0.dmg
```

The disk image contains the app, an `/Applications` drop target and a short read-me about
the first-launch step, so installing is: open the image, drag the app across.

Packaging uses **only `hdiutil` and `codesign`** — both ship with macOS. No `create-dmg`,
no Homebrew, nothing to install, which keeps a release reproducible on any stock Mac. The
`-dmg` script verifies its own output by mounting the image and checking the app inside it
is present, runnable and identical to the build it was made from; a broken image fails at
build time rather than after someone downloads it.

A universal binary (Apple Silicon + Intel) is built automatically **when full Xcode is
present**, since that needs `xcbuild`. With only the Command Line Tools the build falls
back to the host architecture, and the script says so. A tagged `v*` push makes GitHub
Actions build the image and attach it to a Release.

There are **no third-party dependencies**. SourceDesk uses SwiftUI, AppKit, PDFKit
and Network, plus SQLite and zlib, which ship with macOS. Vector search, keyword
search (SQLite FTS5), HTML extraction, PDF/DOCX/EPUB reading, zip archives and
SHA-256 are all implemented in the repository, which is why the app builds offline
and has no supply chain to audit.

### Testing

```bash
swift run SourceDeskHarness            # all suites: ~152 tests, ~990 assertions
swift run SourceDeskHarness -f "6 ·"   # one suite
SOURCEDESK_LIVE_WEB=1 scripts/test.sh  # also exercise the public internet
```

`scripts/test.sh` is the CI gate and exits non-zero on failure. See
[Testing](#testing-approach) for why the tests live in an executable rather than
`swift test`.

## First run

1. **Create a notebook** (⇧⌘N) and add sources: ⇧⌘U for a website, ⇧⌘O for files,
   or drop files onto the window. Folders are scanned recursively.
2. **Ask a question** in the Research tab. With no model configured, SourceDesk
   says so and tells you what to do rather than failing silently.
3. **Pick a model** from the toolbar picker. If Ollama is installed, your models
   appear automatically; SourceDesk never downloads one for you.

### Setting up a local model

```bash
brew install ollama          # or download from ollama.com
ollama serve                 # if it is not already running
ollama pull llama3.2         # ~2 GB, fast and capable for note-sized questions
ollama pull nomic-embed-text # optional: better semantic search
```

Then choose **Ollama** in the toolbar and (optionally) set embeddings to
*Local model* in Settings → Retrieval.

### Research a topic

Command palette (⌘K) → **Research & Add Sources…**, or the **+** menu in the toolbar.
Give it a topic and SourceDesk searches the web, downloads the top results and indexes
them as ordinary sources — downloaded, extracted, cleaned, chunked and embedded, exactly
like a page you pasted in yourself. **Research & Write a Note…** does the same and then
writes a summary note from what it found.

Two things it deliberately does *not* do:

- **It never builds a source out of a search snippet.** A snippet is a fragment of a
  results page, not the author's text, so treating it as the source would mean citing
  words the source never wrote. Every researched source is the real page or it is
  reported as a failure.
- **It never saves an empty source.** If a page cannot be downloaded, or downloads but
  yields no readable text, it is marked failed with an explanation rather than appearing
  in the sidebar as a source that cites nothing.

A run over several pages is cancellable, shows progress per page, and keeps whatever it
already indexed when cancelled.

### Ollama's hosted API

Ollama serves one API from two places: a server on your Mac, and `https://ollama.com`,
where the same `/api/tags`, `/api/chat` and `/api/embed` routes run models far too
large for a laptop (the live catalogue currently lists 20, from `gpt-oss:20b` up to
`glm-5.1`). SourceDesk supports both.

To use it: create a key at [ollama.com/settings/keys](https://ollama.com/settings/keys),
then Settings → AI Providers → **Ollama Cloud** → *Add API Key*. The key goes in the
Keychain like every other credential.

Two details worth knowing, both learned from the live endpoint:

- **The catalogue is readable without a key but generation is not.** SourceDesk
  therefore shows you what exists before you have a key, and tells you plainly that
  generation needs one — rather than showing an empty list.
- **Hosted models report no download size.** Their `size` field is the *uncompressed*
  weight — `glm-5.3` reports 755 GB — so SourceDesk shows the parameter count (read
  from the model name, since the catalogue leaves `details` blank) and never presents
  that figure as a download.

Everything else about it is a cloud provider: it requires the per-notebook
confirmation, it is disabled by Local-Only Mode, it is refused when you are offline,
and answers from it are labelled as leaving your Mac.

### Cloud providers

Settings → AI Providers stores keys in the **macOS Keychain** — never in the
notebook, a settings file, a log or an export. Two things worth being clear about:

- A **ChatGPT Plus or Claude Pro subscription is not an API key**. SourceDesk uses
  the official APIs, which are billed separately by those vendors. The app says this
  in the UI rather than implying otherwise.
- Cloud use requires a **per-notebook confirmation** before any source text leaves
  the Mac, and **Local-Only Mode** disables cloud providers entirely.

## How answers stay grounded

```
Sources → download/extract → clean → chunk → embed → store (SQLite + FTS5)
                                                              │
Question ──► hybrid retrieval (semantic + keyword, fused) ─────┘
             └─► rerank ─► context assembly ─► model ─► citation validation ─► answer
```

1. **Retrieval** runs semantic vector search and SQLite FTS5 keyword search in
   parallel and merges the rankings with reciprocal-rank fusion, so losing either
   method degrades recall instead of breaking search.
2. **Reranking** re-scores candidates on term coverage, phrase proximity and heading
   agreement — in milliseconds, with no model. A model-based reranker is available
   and falls back to the lexical one if the model is unavailable.
3. **Context assembly** assigns `[Source N]` / `[Web N]` markers. Markers are
   assigned in exactly one place, so a citation can never refer to something that was
   not in the prompt.
4. **Validation** re-reads the answer, resolves every marker against the material
   that was actually supplied, and strips any marker that does not resolve. The
   retrieval trace (chunks, scores, timings) is stored with the message, so the
   "show your work" panel works even after a restart or an import.

## Privacy

| Scope | What leaves this Mac |
|---|---|
| Local model (including a server elsewhere on your own network) | Nothing. Model, embeddings and index all run on hardware you control. |
| Ollama's hosted API, OpenAI, Anthropic | The retrieved passages and your question, sent to your chosen provider. |
| Web search | Your search query, sent to your chosen search provider. |
| Everything else | Nothing. No telemetry, no analytics, no accounts, no update pings. |

Settings → Privacy shows this table live, including which notebooks you have
approved for cloud use, with a revoke button for each. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#privacy-model) for the details.

## Import and export

`⇧⌘E` exports the current notebook to a `.nbk` archive — a plain zip:

```
My Notebook/
├── notebook.json        notebook, sources, sessions, notes, chunks
├── sources/<id>/        content.txt, original files
├── chats/*.md           readable transcripts
├── notes/*.md           readable notes
└── embeddings/*.jsonl   optional vectors, so an import need not re-embed
```

`⇧⌘I` imports one, always as a **new** notebook, so importing twice can never
overwrite existing work. API keys and application settings are never included.

## Keyboard shortcuts

| | |
|---|---|
| ⌘N | New notebook |
| ⇧⌘N | New notebook |
| ⌘K | Command palette |
| ⌘1 … ⌘5 | Research · Sources · Notes · Study Tools · Search |
| ⇧⌘U | Add website |
| ⇧⌘O | Add files |
| ⇧⌘E / ⇧⌘I | Export / import notebook |
| ⇧⌘R | Refresh model lists |
| ⌘↩ | Ask |
| ⌘. | Stop generating |
| ⌘F | Filter notebooks (sidebar) |

## Testing approach

Two things about this project's testing are unusual, and both are deliberate.

**The tests are an ordinary executable, not `swift test`.** Apple's Command Line
Tools ship without the XCTest and swift-testing bundles, and without the macro
plugins SwiftData needs. The suites therefore live in `Tests/Harness` and run via
`swift run SourceDeskHarness`, with a small assertion framework in
`Tests/Harness/TestKit.swift`. This keeps the whole project buildable and *testable*
with only the Command Line Tools, and the harness reports the same pass/fail detail
`swift test` would.

**Provider behaviour is tested against a real HTTP server.** `LocalHTTPServer` in the
harness is a small socket server; the Ollama, OpenAI and Anthropic providers are
exercised with real `URLSession` requests, real streaming, real status codes and real
error bodies. That is what catches the bugs that matter — a mis-parsed SSE line, a
missing header, a multi-byte character split across a stream chunk — which a mocked
transport would not.

The suites cover persistence and restart, HTML extraction, chunking, embeddings,
hybrid retrieval, every provider's request/response shape and failure modes, web
search, study-tool parsing, export/import round trips, settings migration, offline
behaviour, and full product flows end to end (ingest → retrieve → answer → cite →
export → import → answer again).

**A test that cannot run is reported as unverified, never as a pass.** Tests needing a
real model or a live network skip with a reason, and the summary prints them separately:

```
PASS  20 suites · 207 tests · 1228 assertions · 0 failures · 203 verified

NOT VERIFIED (4 — these could not run in this environment):
  ~ 20 · Live local model → a real model answers from the sources and cites them
      no local Ollama model is installed, so grounded answering with a real model is unproven
```

`203 verified` is a different claim from `0 failures`, and the distinction is the point:
most of the pipeline is tested with a stub provider, which says nothing about whether a
real model, given real retrieved passages, actually answers from them. Suite 20 answers
that question against **whatever Ollama has installed** — including the
anti-hallucination check, which asks a question the sources cannot answer and requires the
model to decline rather than invent a figure. Run `ollama pull llama3.2` and it runs for
real.

Suite 21 keeps that honest in the other direction: it drives the same assertions through a
scripted Ollama server, so a suite that only ever skips cannot quietly rot into something
that would fail the moment a model appeared.

**Packaging is tested too.** `scripts/test.sh --release` builds the bundle and the disk
image and then inspects them: that the Info.plist parses and declares what a Mac app
needs, that the app requests no camera/microphone/location entitlements, that the image
mounts, that the packaged binary is byte-identical to the build it came from, and that the
image carries the read-me explaining the first-launch step. A packaging step is otherwise
only exercised on release day, which is the worst time to find out it broke.

## Project layout

```
Sources/SourceDeskCore/     the engine: no UI, no AppKit
├── Ingestion/              HTML/PDF/DOCX/EPUB/RTF readers, web downloader, robots.txt
├── RAG/                    chunking, embeddings, hybrid retrieval, context assembly
├── AI/                     provider protocol, Ollama, OpenAI, Anthropic, prompts, engine
├── Search/                 search providers, reachability
├── Study/                  study-tool generators and output parsers
├── Export/                 .nbk archive format
└── Settings/               settings model, diagnostics log

Sources/SourceDesk/         the SwiftUI app
├── App/                    entry point, AppState, view models' host
├── ViewModels/             chat and study-tool view models
└── Views/                  sidebar, research, sources, inspector, notes, settings

Tests/Harness/              verification suites (see above)
scripts/                    test, screenshot and release helpers
docs/                       architecture and format documentation
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the design and
[docs/NOTEBOOK_FORMAT.md](docs/NOTEBOOK_FORMAT.md) for the export format.

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
Please run `scripts/test.sh` before opening a PR.

## License

MIT — see [LICENSE](LICENSE).

SourceDesk is not affiliated with, endorsed by, or derived from Google NotebookLM,
OpenAI, Anthropic, Brave or Tavily. Provider and product names are trademarks of
their respective owners and are used only to describe interoperability.
