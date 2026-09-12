# SourceDesk Architecture

SourceDesk is a native macOS application in Swift: SwiftUI for the interface, and a
UI-free engine (`SourceDeskCore`) for everything else. The split is strict — the core
target links no SwiftUI and no AppKit, which is what lets the whole engine be tested
from a command-line harness.

## Why it is built this way

Three constraints shaped the design, and every non-obvious decision follows from one
of them.

**1. Local-first is a data-layout decision, not a feature flag.** Everything the user
owns lives in one folder that can be copied to another Mac:

```
~/Library/Application Support/SourceDesk/
├── library.sqlite          notebooks, sources, chunks, vectors, chat, notes, settings
├── content/<source-id>/    content.txt (extracted text) + original file
├── cache/                  short-lived downloads
└── logs/                   rotating plain-text diagnostics
```

An export is the same structure inside a zip, which is why export is a small amount
of code and why an imported notebook behaves identically to a native one. Nothing is
stored in `UserDefaults`, because settings should travel with the library they
describe.

**2. No third-party dependencies.** SQLite (with FTS5 for keyword search) and zlib
are already on every Mac. Everything else — HTML extraction, PDF text, DOCX/EPUB
reading, zip read/write, SHA-256, Markdown parsing, vector math — is implemented
here. The app builds offline, has no supply chain, and `swift build` is the whole
build. The cost is roughly 19k lines including tests; the benefit is that a research
tool holding someone's private documents does not pull in anyone else's code.

**3. The engine must be runnable without a UI.** Apple's Command Line Tools ship
without XCTest, swift-testing and the SwiftData macros, so `swift test` and `@Model`
are both unavailable to this project. Rather than take on a dependency or give up on
verification, persistence is a small hand-written SQLite layer and the tests are an
executable target. `swift run SourceDeskHarness` runs 152 real tests with real
assertions. See [Testing](#testing) below.

## High-level flow

```
                     ┌──────────────────────── ingest ────────────────────────┐
 URL / file / text ─►│ download (robots.txt) → extract → clean → chunk → embed │─► SQLite
                     └────────────────────────────────────────────────────────┘
                                              │
                     ┌─────────────────────── retrieve ───────────────────────┐
 question ──────────►│ vector search (cosine)  ┐                             │
                     │ FTS5 keyword search     ├─► reciprocal-rank fusion    │
                     │ metadata / source scope ┘   → rerank → budget trim     │
                     └────────────────────────────────────────────────────────┘
                                              │
                                    context assembly ([Source N], [Web N])
                                              │
                     ┌──────────────────────── answer ────────────────────────┐
                     │ provider.stream(...) → deltas ─► citation validation    │
                     └────────────────────────────────────────────────────────┘
                                              │
                                    answer + citations + retrieval trace
```

## Layering

### 1. Persistence (`NotebookStore`, `SQLiteDatabase`, `StoreSchema`)

`SQLiteDatabase` is a thin typed veneer over the C API: prepared statements, bound
values, transactions, and a little care around the details that bite — text binding
lifetimes, `sqlite3_changes` after a write, and float vectors stored as little-endian
`Float32` blobs (compact and exactly round-trippable).

`NotebookStore` is the only thing that knows SQL. It exposes typed operations
(`upsert(source:)`, `replaceChunks(...)`, `keywordSearch(...)`) and hides the rest.
Two invariants matter:

- **A source's chunks and vectors are replaced in one transaction.** Re-indexing can
  never leave a source half-updated, and a failure rolls back to the previous set.
- **`chunks.source_id` and `embeddings.chunk_id` are foreign keys.** Anything that
  writes chunks writes the source row first. This bit twice during development —
  both times in the *import* and *re-add* paths, which is exactly where a
  half-written row is hardest to notice.

`PRAGMA user_version` drives forward-only migrations. A library written by a newer
build is refused with "update the app" rather than opened and possibly corrupted.

### 2. Ingestion (`Ingestion/`)

Every input type converges on one value:

```swift
struct ExtractedDocument {
    var title: String; var author: String?; var publishedAt: Date?
    var method: String            // "readability", "pdfkit", "ooxml", …
    var pages: [ExtractedPage]    // page-attributed blocks
}
struct ExtractedPage { var number: Int; var blocks: [ExtractedBlock] }
struct ExtractedBlock { var kind: Kind; var text: String; var headingPath: String }
```

One representation means chunking, retrieval, citation rendering, export and the
inspector all have exactly one code path, and `method` travels to the UI so provenance
is never mysterious.

**HTML.** `HTMLTokenizer` is a tolerant tokenizer (never throws, handles unclosed
tags, attribute quoting variants, raw-text elements, entities) feeding a DOM.
`HTMLExtractor` then scores candidate containers readability-style — text length
weighted by punctuation density, penalised for link density, adjusted by element role
and class hints — and walks the winner in document order, tracking a heading stack so
every block knows its section. Chrome is suppressed on its merits (link-dense,
text-poor) rather than by matching a site's class names. It refuses to return an
empty document: a client-rendered app shell produces "this page appears to render its
content with JavaScript only" and a suggestion, not a silent blank source.

**PDF** via PDFKit, one `ExtractedPage` per page so citations can name a page. A PDF
with no text layer is reported as a scan (SourceDesk does not OCR) instead of
importing nothing. **DOCX/EPUB** are read directly as OOXML/zip containers, keeping
heading structure. **RTF** is reduced to visible text runs.

**WebDownloader** is where the failure modes live, and each has a specific error:
redirects followed with a cap, `Content-Length` *and* actual size checked, content
types filtered (a PDF URL is redirected to the document importer), 401/403/404/429/451
distinguished, common sign-in and paywall gates detected in a 200 response, encoding
sniffed from the header or a meta tag. **robots.txt is consulted by default**, parsed
per the specification (longest matching rule wins, `Allow` wins ties) and cached per
origin — *including the port*, because a robots.txt for `:8080` is not the one for
`:80`.

### 3. RAG (`RAG/`)

**Chunking** splits on sentence boundaries with overlap, preserving heading paths and
page numbers, and keeps tables and code blocks whole. Sentences are split with
awareness of abbreviations, initials and decimals — "Dr. Smith", "3.5 percent" and
"e.g." do not end sentences. Undersized tail chunks merge into their neighbour, since
a two-line chunk retrieves badly.

**Embeddings** sit behind one protocol with three implementations:

| Provider | What it is | Why it exists |
|---|---|---|
| `BuiltInEmbedder` | Deterministic 384-dimension lexical vectors: stemmed unigrams, adjacent bigrams and character 4-grams hashed with the signed hashing trick | Works instantly on any Mac: no download, no server, no network, no privacy question. Explicitly *lexical* — it will not connect "car" to "automobile" |
| `OllamaEmbedder` | `/api/embed` on a local server | True semantic recall when the user pulls an embedding model |
| `disabled` | Keyword search only | A deliberate, supported choice |

The provider's `identifier` is stored beside every vector, so a library indexed with
one model and queried with another is detectable rather than silently wrong.

**Retrieval** (`RetrievalEngine`) runs both channels and fuses them:

1. Semantic: cosine similarity over stored vectors, scoped to eligible sources.
2. Keyword: FTS5 `MATCH` with a sanitised query, widened with stem variants so
   morphology does not defeat token matching.
3. Fusion: reciprocal-rank fusion (k=60), with a small bonus when both channels found
   a chunk.
4. Reranking: `LexicalReranker` scores term coverage, best-window proximity, heading
   agreement and saturating term frequency. A model reranker is available and falls
   back to lexical on any failure.
5. Diversity: a per-source cap is a *guarantee* when several sources are eligible (a
   600-page report must not bury a two-page memo), and is lifted for single-source
   notebooks so the context budget is still filled. When the cap shortens the result
   set, the trace says so and points at the setting.
6. Budget: chunks are added until the token budget is reached.

Both channels and the reranker fail independently and degrade with a notice. A
retrieval that finds nothing raises `insufficientContext` rather than sending an
empty prompt to a model that will then hallucinate.

**Context assembly** (`ContextAssembler`) is the only place markers are assigned —
`[Source N]` for notebook material, `[Web N]` for search results, in separate labelled
sections. This is what makes citation validation possible: the set of legal markers is
known before the model runs.

### 4. AI layer (`AI/`)

`AIProvider` is the contract:

```swift
protocol AIProvider: Sendable {
    var identifier: String { get }
    var isLocal: Bool { get }
    var isConfigured: Bool { get }
    func availability() async -> ProviderAvailability
    func availableModels() async throws -> [ModelDescriptor]
    func generate(_ request: AIRequest) async throws -> AIResponse
    func stream(_ request: AIRequest) -> AsyncThrowingStream<StreamEvent, Error>
    func embed(_ texts: [String], model: String) async throws -> [[Float]]
}
```

- **OllamaProvider** detects a running server, lists installed models with size,
  quantisation and parameter count, and reports "not installed" separately from "not
  running" — because the fixes differ (`ollama pull` vs `ollama serve`). SourceDesk
  never installs or downloads a model.
- **OpenAIProvider** speaks `POST /v1/chat/completions` with a configurable base URL,
  so a compliant gateway or self-hosted server works too.
- **AnthropicProvider** speaks the Messages API with the system prompt as a top-level
  field and SSE event types handled individually, including in-stream error events.

`LineStream` buffers raw bytes and yields whole lines. This matters more than it
looks: decoding each network chunk independently corrupts any multi-byte character
that straddles a chunk boundary, which is exactly what happens with accented text and
CJK — a bug that a mocked transport would never surface. The harness tests it
explicitly with Japanese, French and emoji payloads.

`HTTPClient` maps transport and HTTP failures onto specific errors: 401 → invalid key,
404 → check the model name, 413 → context too large, 429 → rate limited (with
`Retry-After`), 5xx → provider unavailable, timeouts and DNS failures distinguished.
An empty response from a model is its own error, because a blank answer is
uninterpretable.

Credentials live in the Keychain via `KeychainService`, scoped to a service name.
Nothing in the persistence or export path can reach a secret: settings encode a
struct with no key field, and the export manifest is built from store rows only.

### 5. Answer engine (`AI/AnswerEngine.swift`)

The whole pipeline in one place, emitting events (`.stage`, `.delta`, `.reasoning`,
`.finished`, `.failed`) so the UI can show progress and stream text. It:

1. Resolves the provider and refuses cloud use when Local-Only Mode is on, when
   offline, when the key is missing, or when consent has not been granted — each with
   a distinct, actionable error.
2. Retrieves, then searches the web if the scope allows and the network is up.
3. Fails before spending a request when the estimated prompt obviously exceeds the
   model's window.
4. Builds the prompt from `PromptBuilder`, whose grounding rules are original to this
   project: answer primarily from the supplied material, cite only with the given
   markers, never cite something a source does not say, and state plainly when the
   material does not answer the question.
5. Validates the answer's citations and strips unresolvable markers.
6. Returns the answer, the resolved citations, the retrieval trace, usage, timings and
   notices.

`PromptBuilder.retrievalQuery` rewrites a short or pronoun-heavy follow-up ("what
caused it?") by appending the salient terms of the previous question, mechanically,
without an extra model call.

### 6. Application layer (`Sources/SourceDesk/`)

`AppState` is the only coordinator. It owns the store, the provider registry, the
network monitor and settings, and it is the only place services are constructed — so
views never touch the database or a provider. `ChatViewModel` and
`StudyToolsViewModel` drive the engine and turn events into observable state; they
hold no database handle.

The UI is a three-column `NavigationSplitView`: sidebar (notebooks, favorites,
recent, settings), working area (research / sources / notes / study tools / search)
and inspector (selected source, citations, retrieval detail, note provenance). A ⌘K
palette searches notebooks, sources, notes and sessions alongside commands, ranked so
an exact content match beats a fuzzy command match.

Design rules are deliberate: typography and spacing carry hierarchy; colour is
reserved for meaning (source status, privacy level, citation kind); no gradients,
glow, oversized cards or fake statistics. Every empty state explains what the panel is
for and offers the action that fills it.

**Rendering citations.** An answer is one `Text` per block, built from an
`AttributedString` in which each marker is a link on a private URL scheme, handled by
an `OpenURLAction`. An earlier version laid out separate text fragments and buttons in
a custom flow layout; that clipped any run wider than the column — which is to say
every real sentence. Text layout is not worth reimplementing, and `AttributedString`
plus `Text` gives correct wrapping, line breaking and selection while still
delivering the tap.

## Privacy model

| Data | Where it goes |
|---|---|
| Notebooks, sources, extracted text, chunks, vectors, chat, notes, settings | Local database + `content/` folder. Never transmitted. |
| Retrieved passages + question | The selected provider. On a local provider: nowhere. |
| Search query | The selected search provider, only when web search is enabled for that answer. |
| API keys | macOS Keychain, scoped to this app. Never in the database, an export or a log. |
| Diagnostics | Plain-text file in `logs/`. Nothing is transmitted, ever. |

`PrivacyLevel` (`.local`, `.cloud`, `.web`) is a type, not a label: the UI states the
level per source, per model, per search and per answer, so "what leaves this Mac" is
answerable at any point in the interface. Cloud sending requires per-notebook approval
(`settings.cloudApprovedNotebooks`), revocable from Settings → Privacy or the command
palette.

## Error handling

`SourceDeskError` is one enum covering ingestion, documents, retrieval, providers,
search and storage. Every case carries an `errorDescription` and, where there is a fix,
a `recoverySuggestion` naming the actual remedy ("run `ollama pull llama3.2`", "turn
off Local-Only Mode in Settings → Privacy"). Some are computed from their payload, so
the advice matches the cause — a cloud refusal caused by withheld consent points at
the consent banner, while one caused by Local-Only Mode points at Settings.

The rule for the UI is that a failure is *recorded and explained*: a source that
cannot be fetched keeps its row with a red status, the message and the remedy, which
is why "3 sources, 1 failed" is a state the app can show rather than a silent loss.

## Testing

`Tests/Harness` is an executable target. `TestKit.swift` provides a small assertion
framework (`check`, `equal`, `close`, `contains`, `expectError`, per-test notes) and
`Harness.run` reports per-suite, per-test and per-assertion results, exiting non-zero
on failure.

Two choices are worth calling out:

- **A real HTTP server.** `LocalHTTPServer` is a socket server on an ephemeral port.
  Providers are exercised through real `URLSession` requests: real streaming framing
  (SSE and NDJSON), real status codes, real error bodies, real header assertions. It
  caught two bugs that a mocked transport could not — the Ollama stream actually being
  NDJSON rather than SSE, and `LineStream`'s multi-byte handling being testable at all.
- **Full product flows.** `EndToEndSuite` drives the same objects the app composes:
  ingest a page from a local server → chunk → embed → retrieve → answer through a stub
  model → validate citations → export → import into a fresh library → retrieve and
  re-answer. It also asserts the negative cases: that a fabricated `[Source 7]` is
  stripped and reported, that robots.txt disallow prevents the request entirely, that
  a cloud provider without consent is never contacted (the server asserts it received
  nothing), and that an offline Mac still answers from local sources.

The suite is the specification: if a behaviour is not asserted somewhere, assume it is
not guaranteed.

## Performance notes

- Ingestion, embedding and generation are all cancellable and report progress; a
  600-section import is interruptible and leaves no partial source.
- SQLite runs in WAL mode with `synchronous = NORMAL`. Batched writes go through one
  transaction: 4,000 chunks plus 1.5M float values commit in about half a second.
- Retrieval is O(stored vectors) per query with a cosine pass in Swift, which is fast
  to tens of thousands of chunks. The `RetrievalEngine` boundary is where an ANN index
  would go if a library ever needed one.
- The UI never blocks: every long operation is a `Task`, and the main actor only
  receives progress and results.

## Extending

- **A new source type**: add a case to `SourceKind`, an extractor producing
  `ExtractedDocument`, and register it in `DocumentExtractor.kind(for:)`. Chunking,
  retrieval, citations, the inspector and export need no changes.
- **A new AI provider**: conform to `AIProvider` and register it in
  `ProviderRegistry.standard`. A chat session that recorded a provider id keeps
  working.
- **A new search provider**: conform to `SearchProvider` and add a case to
  `SearchEngine`.
- **A new study tool**: add a case to `NoteKind`, an output contract in
  `PromptBuilder.outputContract(for:)`, and a retrieval query in
  `StudyToolsService.retrievalQuery`.
