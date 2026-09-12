# The `.nbk` notebook format

A SourceDesk export is a **plain zip archive** with the `.nbk` extension. There is no
proprietary container and no obfuscation: `unzip` it, read it in any text editor, or
process it with a script. The format is documented here so that stays true, and so
other tools can read a SourceDesk notebook.

Format version: **1**

## Layout

```
<notebook title>/
├── notebook.json          the manifest: notebook, sources, chunks, sessions, notes
├── sources/
│   └── <source-id>/
│       ├── content.txt    the extracted, cleaned text that was indexed
│       └── original-<name>  optional: the original downloaded file
├── chats/
│   └── <title>-<id>.md    readable transcript with citations
├── notes/
│   └── <title>-<id>.md    readable note, with YAML front matter
└── embeddings/
    └── <source-id>.jsonl  one vector per line, optional
notebook.json              a duplicate manifest at the archive root
```

The manifest is written twice: inside the notebook folder, and at the archive root.
That way the file remains self-describing even if a user renames or re-nests the
folder inside the archive.

## `notebook.json`

```jsonc
{
  "format": "sourcedesk-notebook",
  "formatVersion": 1,
  "generator": "SourceDesk 1.0.0",
  "exportedAt": "2024-06-02T10:15:30Z",

  "notebook": {
    "id": "…", "title": "…", "summary": "…",
    "createdAt": "…", "updatedAt": "…", "lastOpenedAt": "…",
    "isFavorite": false, "isArchived": false,
    "defaultScope": "notebookSources", "accentIndex": 0
  },

  "sources": [
    {
      "source": {
        "id": "…", "notebookID": "…", "kind": "website",
        "title": "…", "url": "https://…", "filePath": null,
        "contentPath": "…", "siteName": "…", "author": null,
        "mimeType": "text/html",
        "plainTextBytes": 4210, "originalBytes": 51200,
        "wordCount": 640, "pageCount": null, "chunkCount": 4,
        "status": "ready", "addedAt": "…", "updatedAt": "…",
        "fetchedAt": "…", "checksum": "…", "tags": [], "notes": "",
        "extractionMethod": "readability", "fetchMilliseconds": 412,
        "includeInRetrieval": true
      },
      "chunks": [
        {
          "id": "…", "sourceID": "…", "notebookID": "…",
          "ordinal": 0, "text": "…",
          "headingPath": "Findings › Causes", "pageNumber": 4,
          "startOffset": 0, "endOffset": 1180,
          "charCount": 1204, "tokenCount": 302
        }
      ],
      "contentFile": "sources/<id>/content.txt",
      "originalFile": "sources/<id>/original-report.pdf"
    }
  ],

  "sessions": [
    {
      "session": {
        "id": "…", "notebookID": "…", "title": "…",
        "createdAt": "…", "updatedAt": "…",
        "scope": "notebookSources", "providerID": "ollama",
        "modelName": "llama3.2:3b", "isPinned": false
      },
      "messages": [
        {
          "id": "…", "sessionID": "…", "notebookID": "…",
          "role": "assistant", "content": "…",
          "createdAt": "…",
          "citations": [ /* see below */ ],
          "retrieval": { /* the retrieval trace, see below */ },
          "providerID": "ollama", "modelName": "llama3.2:3b",
          "latencyMilliseconds": 2140,
          "promptTokens": 2010, "completionTokens": 168,
          "isError": false
        }
      ]
    }
  ],

  "notes": [
    {
      "note": {
        "id": "…", "notebookID": "…", "title": "…", "body": "…",
        "kind": "quiz", "createdAt": "…", "updatedAt": "…",
        "sourceIDs": ["…"], "providerID": "ollama", "modelName": "llama3.2:3b",
        "payload": {
          "flashcards": [ { "id": "…", "front": "…", "back": "…", "sourceMarker": "[Source 1]" } ],
          "quizItems": [ { "id": "…", "question": "…", "choices": ["…"], "answerIndex": 0,
                           "explanation": "…", "sourceMarker": "[Source 1]" } ]
        },
        "isPinned": false
      }
    }
  ],

  "embeddingModels": ["builtin-hash-384"],
  "counts": {
    "sources": 4, "chunks": 12, "embeddings": 12,
    "sessions": 1, "messages": 2, "notes": 3, "contentBytes": 24810
  }
}
```

All dates are ISO-8601 with a UTC offset. Enum values (`kind`, `status`, `scope`,
`role`, `defaultScope`, `rerankStrategy`, …) use the raw values documented in
`Sources/SourceDeskCore/Types.swift`.

### `citations[]`

```jsonc
{
  "id": "…",
  "kind": "notebook",          // or "web"
  "marker": "[Source 1]",      // exactly as it appears inline in the answer text
  "sourceID": "…",             // notebook sources only
  "chunkID": "…",
  "title": "…",
  "location": "https://…",
  "url": "https://…",
  "pageNumber": 4,
  "headingPath": "Findings › Causes",
  "excerpt": "…",              // the passage, so the citation is verifiable offline
  "score": 0.87
}
```

`marker` is the important field: the answer text contains `[Source N]` inline, and a
consumer resolves those against this array. Every marker in a stored answer is
guaranteed to resolve, because SourceDesk strips unresolvable markers before saving.

### `retrieval` (the trace)

```jsonc
{
  "query": "what caused the decline?",
  "candidateCount": 34,
  "hits": [
    {
      "chunkID": "…", "sourceID": "…", "sourceTitle": "…",
      "semanticScore": 0.71, "keywordScore": 5.4,
      "fusedScore": 0.92, "rerankScore": 0.88,
      "pageNumber": 4, "headingPath": "Findings › Causes",
      "preview": "…", "embeddingModel": "builtin-hash-384",
      "usedInContext": true
    }
  ],
  "usedTokens": 1842, "contextBudget": 8192,
  "semanticEnabled": true, "keywordEnabled": true, "rerankEnabled": true,
  "webResultCount": 0, "notes": ["…"], "durationMilliseconds": 38
}
```

The trace is what powers the "show your work" panel, and it survives export and
import, so an imported conversation can still explain itself.

## `embeddings/<source-id>.jsonl`

One JSON object per line, so the file can be streamed and need not be loaded whole:

```jsonc
{"chunkID":"…","sourceID":"…","model":"builtin-hash-384","dimensions":384,"vector":[0.013,-0.041,…]}
```

Vectors are optional and only written when the export options include them. They are
an optimisation: importing without them re-embeds from `content.txt`, which is
lossless but slower. If the importing Mac uses a different embedding model, the stored
vectors are ignored for search and the source should be re-indexed.

## Markdown side-cars

`chats/*.md` and `notes/*.md` are for humans, not for round-tripping. Notes carry YAML
front matter:

```markdown
---
title: Summary · Inspectorate Annual Report 2024
kind: summary
created: 2024-06-02T10:14:00Z
model: llama3.2:3b
---
```

Chats contain the question, the answer, and a `**Sources**` list with each marker,
title, page and URL.

## Guarantees

- **Import never overwrites.** Every import creates a new notebook with fresh
  identifiers, remapping sources, chunks and citations. Importing the same archive
  twice produces two independent notebooks.
- **Paths are not preserved.** Absolute paths from the exporting Mac are dropped and
  replaced with the importing library's own locations, so a restored source is never
  pointing at another machine's disk.
- **Credentials never travel.** API keys live in the Keychain; no key, token or
  application setting is written into an archive.
- **Forward compatibility is checked, not assumed.** A `formatVersion` above what the
  build supports is refused with "update the app" rather than opened.

## Compatibility

The archive uses only deflate (method 8) and store (method 0), with UTF-8 filenames —
the two methods every unzip tool supports. Entries under 64 bytes are stored rather
than deflated. The reader uses the central directory (not a linear scan of local
headers) and tolerates a comment or padding after the end-of-central-directory record,
which is what makes archives written by other tools importable.
