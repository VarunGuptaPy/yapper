# Yap — a local-first voice memory app

> Source of truth across sessions. Sections 1–13 are the spec as written by the owner.
> Section 14 records decisions and verified API facts discovered during implementation.

## 1. What the app does

I tap a mic and ramble (often Hindi-English code-mixed). The app transcribes it, turns it into clean
structured notes (movie/product ideas, people I've met who could be useful, personal rules like
"never eat X", goals, general notes), and stores everything locally on my phone. A chat screen lets
me ask questions like "which of my connections could help with video editing?" or "did I ever have a
movie idea?" and answers from my saved notes. I can add to or refine existing notes by voice or
through chat. Everything is local, with an encrypted backup/restore option.

## 2. How to work

1. Read this spec fully. Ask clarifying questions ONLY if something blocks the current phase. Then
   propose the folder structure and a phase plan and wait for approval.
2. Build ONE phase at a time. After each phase: `flutter analyze` must be clean, tests must pass, and
   give a short manual test checklist for the phone. Then stop and wait.
3. Check pub.dev for current stable package versions instead of guessing. Justify any package not
   listed below.
4. For every external API (Sarvam, LLM provider), read the official docs before writing the client.
   Do not guess endpoint paths or field names.
5. Keep code simple and readable. No premature abstractions beyond the service interfaces described
   here.

## 3. Target and constraints

- Flutter (latest stable), Dart null-safe. Android first; test device is a Samsung Galaxy M34
  (mid-range). Keep code iOS-compatible but don't set up iOS builds now.
- No backend server, no accounts, no analytics, no telemetry. Never log note contents or transcripts.
- API keys are entered in Settings and stored with `flutter_secure_storage`. Never hardcode keys.
  Add a proper `.gitignore`.
- Heavy work (cosine search, JSON parsing of large payloads, encryption) runs in isolates so the UI
  never janks.

## 4. Stack

- State: Riverpod
- DB: `drift` (SQLite) with an FTS5 virtual table
- Audio: `record` (AAC/m4a, 16 kHz mono) + `just_audio` for playback
- HTTP: `dio`
- Crypto: `cryptography` (AES-256-GCM, key derived from passphrase with Argon2id or PBKDF2)
- Files/sharing: `path_provider`, `share_plus`, `file_picker`
- Connectivity: `connectivity_plus`

## 5. Service interfaces (swappable implementations)

```dart
abstract class TranscriptionService { Future<Transcript> transcribe(File audio, {List<String> keyterms}); }
abstract class LlmService { /* chat completion with JSON mode + tool calling */ }
abstract class EmbeddingService { String get modelId; Future<List<Float32List>> embed(List<String> texts); }
```

- `SarvamTranscriptionService`: Sarvam AI Saaras with `mode = "codemix"`. Docs index:
  https://docs.sarvam.ai/llms.txt (Speech-to-Text overview, REST API, Batch API, Keyterm Prompting).
  REST is for audio under 30 s; use the Batch API (async, poll for result) for longer recordings.
  Pass the titles of `person` notes as keyterms so names are transcribed correctly.
- `OpenAICompatibleLlmService` and `OpenAICompatibleEmbeddingService`: configurable base URL, API key,
  and model name in Settings, so they can point at any OpenAI-compatible provider.

## 6. Data model (drift)

- `captures`: id (uuid), audio_path, duration_ms, raw_transcript, status
  (`recorded | transcribing | structuring | awaiting_review | saved | failed`), error, created_at
- `notes`: id (uuid), type (`idea | person | rule | goal | note`), title, body, tags (JSON array),
  created_at, updated_at
- `note_versions`: id, note_id, title, body, tags, changed_at, change_source
  (`voice_merge | chat_edit | manual_edit`)
- `note_captures`: note_id, capture_id (which recordings contributed to a note)
- `note_people`: note_id, person_note_id (links notes to the people they mention)
- `embeddings`: note_id, model_id, dims, vector (blob of float32)
- `notes_fts`: FTS5 over title, body, tags, kept in sync with triggers

Raw transcripts and audio files are never deleted automatically; they're the source of truth.

## 7. Capture pipeline

1. Big mic button with a running timer. Recording saves to `<app docs>/audio/<uuid>.m4a` and creates
   a `captures` row.
2. Transcribe via `TranscriptionService` and store the raw transcript.
3. Embed the transcript, find the top 5 most similar existing notes (see Search), then call the LLM
   with the structuring prompt below plus those candidates.
4. Show a review card for each proposed note with the options **Save as new**,
   **Merge into "<title>"** (only if suggested), **Edit**, and **Discard**.
5. On merge: copy the old version into `note_versions`, call the LLM to produce a merged body that
   keeps every detail from both, save it, and re-embed.
6. The pipeline is resumable: on app start, resume any capture stuck in an intermediate status. If
   offline, leave it queued and retry automatically when connectivity returns. Failed captures show
   an error and a Retry button.

### 7.1 Structuring prompt (system)

> You convert a raw voice transcript, often Hindi-English code-mixed, into structured notes for the
> speaker's personal knowledge base.
> Rules:
> - Write title, body, and tags in English or Roman-script Hinglish. Never use Devanagari.
> - Remove filler words and repetition, but keep every concrete detail: names, places, numbers,
>   reasons, and the speaker's intent and tone.
> - Never invent facts that aren't in the transcript.
> - One transcript can contain several unrelated thoughts; return one note per distinct thought.
> - type is one of: idea, person, rule, goal, note. A "person" note is about a specific individual:
>   who they are, how they met, what they're good at, how they could help.
> - List any people mentioned in `people` (names as spoken).
> - You're given candidate existing notes. Set `merge_target_id` only if the new thought clearly
>   extends or refines that exact note; otherwise null.
> Return ONLY JSON matching the schema.

```json
{
  "notes": [
    {
      "type": "idea",
      "title": "string",
      "body": "string",
      "tags": ["string"],
      "people": ["string"],
      "merge_target_id": "uuid or null",
      "merge_reason": "string or null"
    }
  ]
}
```

Validate the JSON strictly. On invalid output, retry once with the validation error appended; if it
still fails, mark the capture `failed`.

## 8. Search (used by capture matching and chat)

- Hybrid: FTS5 BM25 top 20 plus cosine similarity top 20 (brute force over all vectors in an
  isolate), merged with Reciprocal Rank Fusion (k = 60).
- Optional filters on type and tags, applied before ranking.
- Only compare vectors whose `model_id` matches the current embedding model. If the model changes in
  Settings, show a "Re-embed all notes" action with progress.

## 9. Chat

A tool-calling agent (max 5 tool rounds per message) with these tools:

- `search_notes(query, types?, tags?, limit?)`
- `list_notes(type, limit?)`
- `get_note(id)`, which returns the note with its linked people
- `propose_create_note(type, title, body, tags)`
- `propose_update_note(id, new_title?, new_body?, new_tags?, reason)`

`propose_*` tools never write directly. They render a confirmation card in the chat, and the change
is applied only on Confirm (with versioning as in the capture pipeline).

Chat system prompt, in short: search the notes before answering anything personal; cite the notes
used (the UI renders them as tappable chips that open the note); if the notes don't cover it, say so
plainly and then answer from general knowledge, clearly labeled as such. Chat history is stored
locally too.

## 10. Screens

- **Capture**: mic button, timer, list of recent captures with status, review cards.
- **Notes**: list with type filter chips and a search bar (uses hybrid search), plus a detail view
  with body, tags, linked people, version history, source recordings (audio playback plus raw
  transcript), and manual edit.
- **Chat**: messages, note-citation chips, confirmation cards.
- **Settings**: Sarvam API key; LLM base URL, key, and model; embedding base URL, key, and model;
  backup and restore.

Clean Material 3 design with dark mode. Bottom navigation across Capture, Notes, and Chat, with
Settings in the app bar.

## 11. Backup and restore

- Export produces one `.yapbackup` file: a zip of the SQLite DB (checkpointed first) plus, optionally,
  the audio files, encrypted with AES-256-GCM using a passphrase-derived key (store the salt and KDF
  params in a small header). Offer to exclude embeddings to shrink the file; they get rebuilt on
  restore. Share via the share sheet.
- Restore: pick a file, enter the passphrase, and verify decryption and DB integrity BEFORE touching
  current data. Make an automatic local safety copy of the current DB before replacing it, then
  re-embed if needed.

## 12. Tests (minimum)

- Repository CRUD, versioning on merge, and FTS trigger sync (in-memory drift)
- RRF ranking and cosine search correctness
- Structuring JSON validation, including the retry path
- Backup encrypt → decrypt → restore round trip, and wrong-passphrase rejection
- Capture pipeline state machine resume logic (with fake services)

## 13. Phases

1. **Capture MVP**: project setup, Settings with secure keys, recording, Sarvam transcription (REST
   and Batch), structuring, review card (Save as new / Edit / Discard only), Notes list and detail.
   No embeddings yet.
2. **Search and Chat**: embeddings, hybrid search, notes search bar, chat agent with read-only tools
   and citations.
3. **Merge and refine**: candidate matching in the capture pipeline, merge flow, version history,
   `propose_*` chat tools, people linking.
4. **Backup and restore.**
5. **Polish**: offline queue and auto-retry hardening, re-embed flow, empty and error states,
   performance pass on the device.

---

## 14. Implementation decisions and verified API facts

### 14.1 Decisions taken (with the owner's approval)

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | Android `applicationId` = `com.varungupta.yap`, app label "Yap" | Set before first install; changing it later forces an uninstall that wipes the local DB and audio. |
| D2 | Sarvam model id is a Settings field, default `saaras:v4` | The spec asked for Saaras v3, but Sarvam's docs state keyterm prompting is supported **only** with `model=saaras:v4`. v4 supports `mode=codemix` too, so v4 satisfies both spec requirements. `saaras:v3` remains selectable; keyterms are omitted from the request when v3 is selected. |
| D3 | `mode` is a Settings field, default `codemix` | Spec default. `translit` (fully romanized) is offered as an alternative since notes must be Roman-script anyway. |
| D4 | REST vs Batch cutoff at **25 s** of recorded duration | Sarvam REST hard-fails at 30 s with HTTP 422. A 5 s margin absorbs container/duration rounding. |
| D5 | `permission_handler` is NOT a dependency | `record` exposes `hasPermission()`, which requests `RECORD_AUDIO` itself. One less plugin. |
| D6 | LLM JSON mode uses `response_format: {"type": "json_object"}` | Widest support across OpenAI-compatible providers. Strict schema validation is done client-side anyway, per §7.1. |
| D7 | `minSdk = 24` | `record` needs 23, `flutter_secure_storage` needs 23. 24 is the current Flutter default and covers the Galaxy M34 (Android 13/14) comfortably. |

### 14.2 Sarvam Speech-to-Text — verified against docs.sarvam.ai

Auth header for **every** Sarvam call: `api-subscription-key: <key>`.

**REST (audio ≤ 30 s)** — `POST https://api.sarvam.ai/speech-to-text`, `multipart/form-data`:

| Field | Notes |
|---|---|
| `file` | The audio. m4a/AAC is supported (`mp4`, `x-m4a` codecs auto-detected). |
| `model` | `saaras:v4` (default in Yap) or `saaras:v3`. |
| `mode` | `transcribe` \| `translate` \| `verbatim` \| `translit` \| `codemix`. |
| `language_code` | BCP-47 or `unknown` (auto-detect). Yap sends `unknown`. |
| `keyterms` | **JSON-encoded array in one form field**, e.g. `["Sarvam","New Delhi"]`. Max 50 terms, 64 chars each. `saaras:v4` only. |
| `with_timestamps`, `input_audio_codec` | Not used by Yap (m4a is auto-detected). |

Response: `{ "request_id": string, "transcript": string, "language_code": string|null, "language_probability": double? }`.
Error: `422 unprocessable_entity_error` for bad format, oversize, or audio > 30 s.

**Batch (audio > 25 s)** — five steps, all under `https://api.sarvam.ai`:

1. `POST /speech-to-text/job/v1` with body
   `{"job_parameters": {"model","mode","language_code","keyterms":[...]}}`
   → `202 {"job_id", "storage_container_type", "job_parameters", "job_state":"Accepted"}`.
2. `POST /speech-to-text/job/v1/upload-files` with `{"job_id", "files": ["<uuid>.m4a"]}`
   → `{"upload_urls": {"<uuid>.m4a": {"file_url": "<presigned>"}}, "storage_container_type"}`.
3. `PUT <file_url>` with the raw audio bytes. When `storage_container_type` starts with `Azure`,
   the PUT must carry `x-ms-blob-type: BlockBlob`.
4. `POST /speech-to-text/job/v1/{job_id}/start` → job status object.
5. Poll `GET /speech-to-text/job/v1/{job_id}/status` until `job_state` is terminal.
   `job_state` ∈ `Accepted | Pending | Running | Completed | Failed` (title case).
   Output filenames come from `job_details[].outputs[].file_name` (e.g. `"0.json"`);
   per-file `state` ∈ `Success | API Error | Internal Server Error`.
6. `POST /speech-to-text/job/v1/download-files` with `{"job_id", "files": ["0.json"]}`
   → `{"download_urls": {"0.json": {"file_url": "<presigned>"}}}`. `GET` that URL; the JSON body is
   `{ "request_id", "transcript", "language_code", "timestamps"?, "diarized_transcript"? }`.

Batch limits: 20 files per job, 2 h per file. Diarization is Batch-only; Yap does not use it.

### 14.3 Package notes

- `sqlite3_flutter_libs` is published as `0.6.0+eol` ("Not used anymore, update to version 3.x of
  package:sqlite3"). It is still a transitive dependency of `drift_flutter` and is correct to pull in
  via `drift_flutter`; do not add it directly.
- `record` 7.x API: `AudioRecorder()`, `hasPermission()`, `start(RecordConfig(...), path:)`,
  `stop()` → path, `cancel()`, `dispose()`, `onAmplitudeChanged(...)`.

### 14.4 Decisions taken while building Phase 1

| # | Decision | Rationale |
|---|----------|-----------|
| D8 | All 7 tables ship in `schemaVersion 1`, including `embeddings`, `note_versions` and `note_people` | Phases 2–3 populate them, but creating them now means no drift migration on the only copy of the data. |
| D9 | `storeDateTimeAsText: true` on the database | drift's default stores `DateTime` as unix **seconds**. Two edits to one note inside the same second tied, and version history came back in arbitrary order. Caught by a test. |
| D10 | Review proposals live in memory, not in a table | The spec's schema has nowhere to put them. After a restart, `ensureProposals` rebuilds them from the stored transcript — one LLM call, no re-transcription, and only when the user actually opens the review. |
| D11 | `awaiting_review` is not an "in progress" status for the resumer | It is waiting on a person, not on the app. Sweeping it would silently re-run the LLM on every launch. |
| D12 | Recording is never blocked by missing Settings | `UnconfiguredTranscriptionService` / `UnconfiguredLlmService` let the capture happen and fail the *pipeline* with a message naming what to add. Fill in Settings, tap Retry, and the recording is still there. |
| D13 | Offline holds a capture at `recorded` with an informational error; every other failure goes to `failed` | Matches the spec's split between "queued" and "failed, with Retry". A queued capture stays resumable by both the connectivity listener and the next app start. |
| D14 | Dependencies are injected as **public** final fields | `prefer_initializing_formals` fires on private constructor-injected fields, and its suggested fix (`required this._foo`) is not legal Dart — private named parameters cannot be passed by callers. Public fields keep every lint enabled. |
| D15 | `android:allowBackup="false"` plus `data_extraction_rules.xml` | Google auto-backup would copy the database off-device, and keystore-encrypted API keys cannot be decrypted after a restore anyway. Yap's own encrypted export (§11) is the backup story. |
| D16 | Widget tests stub Riverpod providers instead of using a real drift database | drift's asynchronous queries never resolve under `flutter_test`'s fake clock — the page hangs in its loading state and the test times out with a pending timer. The database is covered directly in `test/db`, which does not pump widgets. |
| D17 | No `permission_handler`, no `go_router` | `record.hasPermission()` already requests `RECORD_AUDIO`; an `IndexedStack` plus `Navigator.push` covers every route in §10 with no deep linking needed. |

### 14.5 Verified package facts

- Dio 5.11's default transformer is `FusedTransformer(contentLengthIsolateThreshold: 50 * 1024)`, so responses over 50 KB are already JSON-decoded in a background isolate. That is the §3 isolate requirement for Phase 1; cosine search (Phase 2) and encryption (Phase 4) still need explicit isolates.
- `flutter_secure_storage` 11 **removed** `encryptedSharedPreferences` from `AndroidOptions` and requires `minSdk 24`. Default options are correct; do not pass the old flag.
- Riverpod 3: `AsyncValue.value` is already nullable (there is no `valueOrNull`), `StateProvider` is legacy (use `Notifier`), and the `Override` type is not publicly exported — tests must construct `ProviderScope` inline rather than pass a typed override list.

### 14.6 Decisions taken while building Phases 2 and 3

| # | Decision | Rationale |
|---|----------|-----------|
| D18 | `schemaVersion 2` adds `chat_messages` | Chat history is required by §9 but was not in the §6 table list. The migration is purely additive; nothing existing is rewritten. |
| D19 | Default embedding model is OpenAI `text-embedding-3-small` | $0.02/1M tokens, and OpenAI does not train on API data by default. Google's free tier was rejected: as of 23 March 2026 its unpaid tier uses submitted content to improve Google products, with human review — unacceptable for notes about real people. At ~1,000 notes the paid cost is under a cent. |
| D20 | Semantic search is best-effort; full-text is not | If embeddings are unconfigured or the provider is down, `HybridSearch` logs and returns text-only results rather than failing. Losing the ability to search your own notes because a third party is down would be the worse failure. |
| D21 | Citations use `[1]`, `[2]`, renumbered on the way out | Models reproduce small integers reliably and mangle UUIDs. The agent rewrites the markers to 1..n in order of first appearance and drops markers for notes it never read, so the text and the chips agree permanently — including after a restart, when the tool session's numbering is gone. |
| D22 | Every note write goes through `NoteWriter` | Capture review, merge, chat proposals and manual edits all need people links and the embedding index updated. One chokepoint means they cannot drift apart. |
| D23 | Embedding failures never block a save | `indexNote` logs and returns. A note that could not be embedded is still fully usable and searchable by text; Settings → "Index new notes" catches it up later. |
| D24 | Creating a person note back-fills links to notes that already name them | Otherwise everything recorded before you had a note about someone stays invisible from their page. FTS finds candidates; a full-name substring check confirms before asserting a link. |
| D25 | A lone first name links only when exactly one person note could be meant | "Ritu" finds "Ritu Sharma" when she is the only Ritu, and links nothing when there are two. Guessing wrong attaches a note to the wrong person silently. |
| D26 | Merge keeps the union of both tag lists locally | The merge prompt asks the model to merge tags, but a dropped tag is silent data loss, so the floor is enforced in code regardless of what comes back. |
| D27 | The agent's final round is forced without tools | After 5 tool rounds it asks once more with `tools` omitted, so a looping model must answer from what it gathered instead of returning an empty turn. |

### 14.6b Bug fixed on device: "Transcript file was not JSON"

Long recordings (the Batch path) failed at the final download step. Blob storage
serves the uploaded output file as `application/octet-stream`, and Dio decodes a
response body into a Map **only when the content type says JSON** — otherwise
`response.data` is a `String`, so the `is Map` check rejected a perfectly good
transcript.

Fix: the transcript download now requests `ResponseType.plain` and decodes the
body itself, accepting a String, raw bytes, or an already-decoded Map, and
stripping a UTF-8 BOM. It also distinguishes the other failure modes instead of
lumping them together — an XML `<Error>` document from storage (an expired or
rejected SAS link) is reported with its `<Code>`, and an empty or unreadable
file names the content type it was served as.

`test/services/dio_contenttype_probe_test.dart` pins the underlying Dio
behaviour so this cannot silently regress.

### 14.7 Status

Phases 1, 2 and 3 complete. `flutter analyze` is clean, 242 tests pass, and
`flutter build apk --debug` succeeds.

Remaining: Phase 4 (backup and restore) and Phase 5 (polish — offline queue
hardening, empty/error states, on-device performance pass).

---

## 15. Design language

Added after Phases 1–3, when the app worked but looked like a form.

### 15.1 The thesis

The brief was "Indian and Japanese, colourful rather than bland". The honest
bridge between the two traditions is not decoration bolted onto a Material app,
it is what they genuinely share:

- **Indigo** is both Indian *neel* and Japanese *ai*; **vermillion** is both
  *sindoor* and *shu*. Those two dyes carry the palette.
- Both build **geometric lattices** — *jali* and *kumiko*, *kolam* and
  *asanoha*.
- The **lotus** (*padma* / *hasu*) is drawn radially in both, as a kolam is and
  as a Japanese *mon* is.

So: Japanese restraint in the layout (space, hairlines, small caps section
rules), Indian saturation in the colour, and motifs that are real in both.

### 15.2 What that became

| Piece | Decision |
|---|---|
| Ground | Warm paper (*washi*) in light, *sumi* ink in dark — never white. |
| Accents | Indigo, vermillion, marigold, deep teal. Each note type owns one, so a list scans by hue before you read a word. |
| Type | `InstrumentSerif` (bundled, 70 KB, OFL) for display sizes only. Body text stays on the platform font, which also keeps Devanagari correct in raw transcripts. |
| Lattices | `asanoha`, `kolam` and `seigaiha` painters, used as faint texture at 5–15% alpha. Louder than that and a notes app turns into a souvenir shop. |
| Lotus | A rosette behind the mic, its outer petals shifting indigo → vermillion while recording. |
| Waveform | See below. |

### 15.3 Decisions taken

| # | Decision | Rationale |
|---|----------|-----------|
| D28 | No large background washes | A low-alpha tint over warm paper goes grey, and a gradient stop leaves a visible band across the screen. Both were tried on device and looked dirty. Colour lives in the lotus, the mic and the type accents instead. |
| D29 | The waveform's coloured strokes fade with actual mic energy | At rest the full-width gradient stroke read as a stray rainbow rule. It now resolves to a short centred hairline that opens outwards as you speak. |
| D30 | The waveform's animation clock stops when idle | A 60 fps repaint on the tab the app opens to costs battery all day. It also meant `pumpAndSettle` could never settle, which is how the cost got noticed. |
| D31 | Capture is recording-only | Past recordings moved to `RecordingsPage`, reachable from the app-bar history icon. A `PendingWorkPill` keeps "2 notes to review" visible, without which a finished transcription would sit unnoticed. |
| D32 | Chat answers render as Markdown | Assistant text is full-width with a thin rule down the left rather than in a bubble — a bubble round several paragraphs is a wall. User turns keep a bubble. |
| D33 | `[1]` citation markers are inline links | Rewritten to `[\[1\]](yapnote:<id>)` before rendering, so the marker is tappable in the sentence as well as in the chips underneath. |
| D34 | Preview renders are excluded from the default suite | `test/ui/preview_test.dart` writes PNGs of populated screens for design review, but golden output depends on the fonts on the machine. `dart_test.yaml` skips the `preview` tag; run it with `--tags preview --update-goldens`. |

### 15.4 Two bugs the previews caught

Rendering the screens and looking at them found things the unit tests did not:

1. **Citations rendered as raw markdown.** `_linkify` built its replacement with
   a raw string, so `$_scheme` and `${citations[...]}` never interpolated and
   every citation displayed as `[[1]]($_scheme:${citations[index - 1]})`. The
   test passed because it asserted `contains('[1]')` — which the broken output
   also contains. The assertion now pins the whole sentence and rejects any
   leftover markdown.
2. **The proposal card overflowed** on a long note title: the `Update "<title>"`
   header row had no `Flexible`.

---

## 16. Phase 4 — Backup and restore

Built after the owner asked what happens on a reinstall. The answer was that
everything is lost: the database, the recordings and the keystore entries all
live in app-private storage, and D15 had already turned Android's own backup
off. Phase 4 is the only way data leaves the phone.

### 16.1 Scope change

**Notes and database only — no audio.** The owner asked for this explicitly,
and it is the right split: recordings are the overwhelming bulk of the bytes
and the notes are what carry the meaning. The format keeps room to add audio
later without a version bump.

### 16.2 The file

A `.yapbackup` is a plaintext header followed by AES-256-GCM ciphertext and its
MAC. The header is readable JSON — magic, format version, KDF name and
parameters, salt, nonce, cipher — so a future version can diagnose a file it
cannot open, and so tuning the KDF never strands old backups.

Inside the encrypted payload is a zip holding `manifest.json` (schema version,
timestamp, note and capture counts, whether embeddings are included) and
`yap.sqlite`.

### 16.3 Decisions taken

| # | Decision | Rationale |
|---|----------|-----------|
| D35 | Argon2id (64 MiB, t=3, p=1) over PBKDF2 | Benchmarked both. Argon2id's pure-Dart implementation does real memory-hard work — timing scales linearly with memory (4 MiB→34 ms, 64 MiB→511 ms on a laptop) — and being memory-hard it resists GPU guessing in a way PBKDF2 does not. The first benchmark looked wrong (more memory, less time) purely because of JIT warm-up. |
| D36 | KDF parameters travel in the header | Hard-coding them would make every existing backup unreadable the day they are tuned. |
| D37 | Verification uses raw `package:sqlite3`, never `AppDatabase` | **This was a real bug.** Opening an arbitrary file through drift runs the migration, which *creates* the missing tables — so any SQLite file on the phone passed verification, and restoring one would have silently replaced every note with an empty database. Verification now checks `integrity_check`, `user_version`, and that all seven Yap tables already exist, without writing anything. |
| D38 | Restore is two-phase | `prepareRestore` decrypts, validates and stages; only `applyRestore` touches live data, after the user confirms against a summary of what the backup actually holds. |
| D39 | The previous database is kept as `yap.sqlite.before-restore-<stamp>` | Restoring the wrong file is otherwise unrecoverable. |
| D40 | `-wal` and `-shm` are deleted during the swap | They belong to the old database; left behind, SQLite can replay stale pages over the new file. |
| D41 | The controller closes the database, not the service | The connection is owned by a provider, and SQLite will not let the file be replaced under an open handle. `ref.invalidate(appDatabaseProvider)` then rebuilds it and everything watching it. |
| D42 | Embeddings excluded by default | Derived data, roughly 6 KB per note, and the dominant cost in the file. Restore offers a one-tap re-index. |
| D43 | The database path lives in `connection.dart` | Backup has to find, copy and replace that exact file. Two independent guesses at the location is how a restore ends up writing next to the live database instead of over it. |

### 16.4 What is *not* in a backup

API keys. They live in the Android keystore, not the database, and keystore
material cannot be exported. After restoring onto a new phone the notes are all
there but Settings is empty — re-enter the three keys.

### 16.4b Bug fixed on device: keyterms with commas

A long recording failed with `Creating the transcription job failed (400). Send
each keyterm as a separate array item; comma-separated and semicolon-separated
values are not supported.`

Keyterms are person-note titles, and one of them was `Archit Sethia, Unirely`.
Sarvam reads a comma or semicolon inside a keyterm as an attempt to pack
several terms into one string and rejects the whole request. `sanitizeKeyterms`
handled length and duplicates but passed separators straight through.

It now splits on `,` and `;` rather than stripping them — such a title really
is two names, and both are worth biasing recognition toward — then collapses
whitespace, trims, de-duplicates and caps at 50 as before. Affects both the
REST and Batch paths, since both share the sanitiser.

### 16.5 Verified on device

Export → share sheet → restore → notes present, on a Pixel emulator with the
real drift isolate: the path unit tests cannot reach, because they use a plain
`NativeDatabase` rather than the isolate-backed connection the app runs on.
`test/backup/make_fixture_test.dart` (tagged `fixture`) writes a seeded
`.yapbackup` to `/tmp` for exactly this; run it with `--run-skipped`.


---

## 17. Multiple chats

Requested after Phase 4: a way to start a fresh conversation without losing the
previous one.

### 17.1 Schema v3

`chat_conversations` (id, title, created_at, updated_at) and a
`conversation_id` on `chat_messages`, cascading on delete.

The migration matters more than the feature: anyone upgrading has real chat
history in the old flat log. v2 → v3 creates the table, gathers every existing
message into one thread titled "Earlier conversation", then uses
`TableMigration` to add the column — which rebuilds the table with the full new
definition, so a migrated database ends up byte-identical in shape to a fresh
one rather than missing the foreign key. Foreign keys are switched off for the
rebuild and back on in `beforeOpen`.

`test/db/migration_v3_test.dart` builds a real v2-shaped database, runs the
real migration, and asserts the messages, their order, the notes, the FTS index
and the foreign-key pragma all come through. It also asserts a user who never
chatted does **not** end up with a phantom empty conversation.

### 17.2 Decisions taken

| # | Decision | Rationale |
|---|----------|-----------|
| D44 | A conversation row is written on the first message, not when "New chat" is tapped | Tapping New chat and backing out would otherwise leave an empty thread in the list every time. |
| D45 | The title is the opening question, truncated to 48 characters | Scannable without paying for an LLM call to write a title. Never rewritten by later messages. |
| D46 | A fresh chat is the default on launch | Each question about your notes is usually independent, and old threads are one tap away. |
| D47 | `recentHistory` is scoped to the conversation | The whole point of a fresh chat is that the model does not carry the previous one in. Tested explicitly. |
| D48 | Deleting a chat spares the notes | Confirmation says so out loud: a `propose_*` card may have created or edited notes that should outlive the conversation. |


---

## 18. Bug: keyterms poisoning transcripts

Reported on device: recordings about **Shivank Tripathi** came back transcribed
as **"Parvesh Rawal - AI expert"**, and other transcripts contained strings of
person-note titles that were never spoken.

### 18.1 Cause

`personNames()` sent the *whole title* of every person note as a Sarvam
keyterm. The structuring model writes person titles descriptively — "Parvesh
Rawal - AI expert, potential co-founder/CTO" — so Sarvam was being handed long
descriptive phrases where its documentation asks for short proper nouns.

Two failures followed, and both were visible in the raw transcripts:

1. **Verbatim emission.** Keyterms appeared word for word in the output,
   punctuation included — nobody says "dash" mid-sentence.
2. **Name substitution.** Biasing hard toward ~10 known names made an
   unfamiliar name snap onto the nearest one. For an app whose job is capturing
   *new* people, this is the worst possible failure: it silently attributes a
   note to the wrong person.

### 18.2 Fix

| # | Decision | Rationale |
|---|----------|-----------|
| D49 | Keyterms are names extracted from titles, never the titles | `extractPersonName` cuts at the first separator (`- – — : , ; ( / |`), keeps the leading run of capitalised words, caps at 4 words and 64 characters. "Parvesh Rawal - AI expert, potential co-founder/CTO" becomes "Parvesh Rawal". |
| D50 | Caseless scripts count as capitalised | Devanagari has no capitals, and a name written in one must not be discarded by a Latin rule. |
| D51 | A Settings switch turns keyterm biasing off entirely | The heuristic reduces the risk but cannot remove it: biasing towards known names inherently works against hearing a new one. Given this corrupted real notes, the owner gets the off switch rather than only a promise that it is better now. |

Keyterms remain capped at 50 and stripped of separators (§16.4b) — a keyterm
containing a comma is rejected by Sarvam outright.

### 18.3 Round two: shortening the keyterms was not enough

With names-only keyterms, Sarvam still transcribed **"Irrfan Khan's Madaari
movie"** as **"Irrfan Khan's Parvesh Rawal movie"**. "Madaari" and "Parvesh
Rawal" are not phonetically close; the substitution happened because a name was
in the bias list at all. The extraction fix was working — the injected string
no longer carried the "- AI expert" suffix — it just was not the whole problem.

Keyterm biasing is phonetic and context-free. It cannot tell that the word it
is about to overwrite is a film title, so on a notebook full of people's names
it corrupts more than it corrects.

| # | Decision | Rationale |
|---|----------|-----------|
| D55 | Keyterm biasing is **off by default** | Demonstrated twice on real recordings to replace unrelated words with known names. The feature is kept behind a switch for anyone whose recordings benefit, but it is not the default. |
| D56 | The setting reads from a new storage key | The previous default was on, so anyone who had opened Settings carried a stored `true` that was never a deliberate choice. A fresh key lets the safer default actually reach them; deliberately turning it back on persists under the new key. |
| D57 | Known names move to the **structuring prompt** | This is where the spec's goal — "so names are transcribed correctly" — actually belongs. The model reads the whole sentence and can tell a person from a film title, which the recogniser cannot. The roster is given with an explicit instruction not to force an unrelated word onto it, so it does not become the same trap one layer up. |

### 18.4 Not fixed

Transcripts already written are still wrong. The audio is kept, so
re-transcribing an existing capture is possible, but there is no UI for it yet:
a saved capture has no path back through the pipeline.


---

## 19. Chat answers from the notes and nothing else

The owner asked for this directly, overriding the general-knowledge fallback in
§9: *"Make it so that it just answers from the notes and adds nothing else of
its own. It could rephrase my notes but notes are its only source of info."*

### 19.1 What changed

The system prompt now states the notes are the only source, in absolute terms,
and spells out the failure it is guarding against — a model that pads an answer
with plausible background is confidently wrong about the speaker's own life,
which is worse than saying nothing.

Specifically it must not add background, context, advice, examples, definitions
or suggestions the notes do not already contain; must not guess or infer beyond
what is written; and when the notes do not answer the question, must say so in
one sentence and stop — not partially, not with a caveat, not "generally
speaking".

### 19.2 What is still allowed

| Still allowed | Why |
|---|---|
| Rephrasing, summarising, combining, quoting, reorganising | Explicitly asked for. The restriction is on *adding*, not on wording. |
| `propose_create_note` / `propose_update_note` | Recording what the speaker just said is not the model asserting something of its own. The rule governs what it may claim, not what they may write down. |
| Answering about itself and what it can do | Otherwise it cannot answer "what can you do?" without a note about itself. |
| One re-worded retry before giving up | A single unlucky query wording should not produce a false "not in your notes". |

### 19.3 Decisions taken

| # | Decision | Rationale |
|---|----------|-----------|
| D52 | The empty-search tool result tells the model to stop, not just that nothing matched | The tool result is the last thing the model reads before answering, so the instruction lands where the temptation to improvise actually arises. |
| D53 | The forced final turn repeats the restriction | Running out of tool rounds must not become a licence to invent an answer. |
| D54 | The prompt's wording is pinned by tests | Prompts drift as they are edited. `chat_agent_test.dart` asserts the notes-only clauses are present and that the old "Generally speaking" fallback is gone. |


---

## 20. Deleting a note from chat

Added on request. `propose_delete_note(id, reason)` joins the other two write
tools and goes through the same gate: the model proposes, a card appears, and
nothing happens until Confirm.

| # | Decision | Rationale |
|---|----------|-----------|
| D58 | The card shows the note's whole body, not just its title | Deleting is the only irreversible action in Yap. If the model picked the wrong note from a vague request ("delete that prawns thing"), that has to be obvious before the button is tapped. |
| D59 | The title is snapshotted onto the proposal | Once the delete is confirmed the note is gone, and the card still has to say what it was. The body is read live, so it disappears from the card after deletion — which is the truthful thing to show. |
| D60 | The card is styled destructively and says what does not come back | Error colours, a red "Its edit history goes too, and cannot be recovered. The recording and transcript stay.", and the buttons read **Delete** / **Keep it** rather than Confirm / Dismiss. |
| D61 | The prompt reins the tool in | "Only propose a delete when the speaker clearly asks for a specific note to be removed. Never delete to tidy up, to resolve a duplicate, or as a way of replacing a note — change it instead." Pinned by a test. |
| D62 | `applyChatProposal` returns `NoteRow?` | A delete leaves no row behind, and returning null is more honest than inventing one. |

The existing `NoteWriter.delete` does the work, so a chat delete clears the
embedding and cascades the version history, capture links and people links
exactly as the manual delete on the note screen already did.


---

## 21. The app icon

Drawn in Flutter by `lib/ui/common/yap_logo.dart` rather than as a separate
image file, so the icon and the app are painted by the same code in the same
palette. `test/tool/generate_icons_test.dart` renders it to every Android
density:

    flutter test test/tool/generate_icons_test.dart --run-skipped

### 21.1 The mark

The lotus from the recording screen, closed around the mic button — the same
*padma* / *hasu* motif, drawn radially as a kolam and a Japanese *mon* both
are. Marigold outer petals, vermillion inner petals offset by half a step,
a warm-paper centre disc, an indigo microphone, on an indigo ground.

Simplified hard for size: eight petals rather than sixteen, two accent colours,
and a solid centre. A launcher icon is read at 48dp.

| # | Decision | Rationale |
|---|----------|-----------|
| D63 | The microphone is one connected silhouette | The first version drew the capsule, stem and base as separate shapes. At 48dp the base dissolved into a detached smudge — checked by magnifying the real mdpi asset, not by assuming. |
| D64 | A real `monochrome` layer is generated | Android 13+ themed icons tint the foreground flat, which would turn a coloured icon into a featureless blob. The monochrome layer is a silhouette with the microphone punched out via `BlendMode.clear`, so it keeps its shape when tinted. |
| D65 | The adaptive foreground is scaled to 60% | Only the middle of a 108dp adaptive layer is guaranteed to survive the launcher's mask. |
| D66 | The logo is used in Settings as well | Otherwise `YapLogo` would be a widget in `lib/` that only a test ever calls. |

Legacy square and round PNGs are generated for pre-API-26 launchers; the
adaptive icon covers everything since.

iOS icons are not generated — iOS builds are still out of scope (§3), and the
same generator will produce them when they are not.


---

## 22. Dark mode

Reported as "gorgeous in light mode, pretty bland in dark". Rendering both side
by side made the causes obvious, and one of them was self-inflicted.

### 22.1 What was wrong

1. **A neutral near-black ground.** Light mode's character comes from its warm
   washi paper; dark had a flat `#121319` void with no equivalent, and the
   container steps were so close together that nothing read as depth.
2. **The mic button had gone pale.** `ColorScheme.primary` becomes a light tint
   in a dark theme, so the largest element on the capture screen rendered as a
   washed-out lavender disc and the lotus receded behind it. Following
   Material's convention had inverted the composition.
3. **Pastel accents.** The dark accents were all light tints of the palette,
   which landed in the same washed-out register.
4. **A dried-blood chip.** The selected filter chip picked up
   `secondaryContainer` (`#7A2B16`).
5. Accent-tinted tiles and tags used a 12% wash that works on paper and
   disappears against ink.

### 22.2 Decisions taken

| # | Decision | Rationale |
|---|----------|-----------|
| D67 | The dark ground is tinted indigo ink, not neutral black | Light mode's warmth came from its paper; dark needs the equivalent, and an indigo-led app should sit on indigo-cast ink. Container steps were spread far enough apart to read as elevation. |
| D68 | The mic fill is `YapAccents.micIdle` / `micActive`, not `ColorScheme.primary` | A brand fill should stay saturated in both themes. Material's pale-primary convention is right for text and tinted surfaces and wrong for the one big filled element on the screen. |
| D69 | Dark accents are saturated, not pastel | Gold, teal, coral and indigo at full strength rather than tints. |
| D70 | `primaryContainer` is the real indigo in dark | Nav indicator, chat bubbles and selected chips now carry the brand instead of a grey-blue wash. |
| D71 | Chips select in indigo | `secondaryContainer` read as dried blood. |
| D72 | `YapAccents.accentFill` carries the tint alpha per theme | 12% on paper, 22% on ink. One number rather than a magic constant at each call site. |

### 22.3 Previews now render at production fidelity

The preview harness loads Flutter's own bundled Roboto **and**
`MaterialIcons-Regular.otf` from `bin/cache/artifacts/material_fonts`, and
patches the button, chip and navigation-bar text styles as well as the
`TextTheme` — component themes carry their own styles and were still rendering
as Ahem boxes. The font directory is found by walking up from
`Platform.resolvedExecutable` (and via `FLUTTER_ROOT`), because the depth from
the Dart binary changes between Flutter versions; the first attempt hard-coded
it, silently found nothing, and regressed every preview to boxes.

Screenshots now write to `docs/screenshots/`, so the golden files and the
images in `README.md` are the same artefacts.
