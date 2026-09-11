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
