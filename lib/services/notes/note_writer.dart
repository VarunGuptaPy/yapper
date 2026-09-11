import '../../data/db/database.dart';
import '../../data/models/enums.dart';
import '../../data/models/structured_note.dart';
import '../../data/repositories/embedding_repository.dart';
import '../../data/repositories/note_repository.dart';
import '../../search/embedding_indexer.dart';
import '../chat/note_proposal.dart';
import '../merge/merge_service.dart';

/// The single place notes are written.
///
/// Every path — a reviewed capture, a merge, a chat proposal, a manual edit —
/// goes through here so that people links and the embedding index can never
/// drift out of step with the note itself.
class NoteWriter {
  NoteWriter({
    required this.notes,
    required this.embeddings,
    required this.indexer,
    required this.merger,
  });

  final NoteRepository notes;
  final EmbeddingRepository embeddings;
  final EmbeddingIndexer indexer;
  final MergeService merger;

  /// Saves a reviewed proposal as a new note.
  Future<NoteRow> createFromProposal(
    StructuredNote proposal, {
    String? captureId,
  }) async {
    final note = await notes.createNote(
      type: proposal.type,
      title: proposal.title,
      body: proposal.body,
      tags: proposal.tags,
      captureIds: captureId == null ? const [] : [captureId],
    );

    await _linkPeople(note.id, proposal.people);
    if (note.type == NoteType.person) {
      await _backfillLinksForPerson(note);
    }
    await indexer.indexNote(note.id);
    return note;
  }

  /// Folds a new thought into an existing note, keeping the old state as a
  /// version first (SPEC.md §7.5).
  Future<NoteRow> mergeIntoExisting({
    required NoteRow existing,
    required StructuredNote incoming,
    String? captureId,
  }) async {
    final merged = await merger.merge(existing: existing, incoming: incoming);

    final updated = await notes.updateNote(
      id: existing.id,
      changeSource: ChangeSource.voiceMerge,
      title: merged.title,
      body: merged.body,
      tags: merged.tags,
    );

    if (captureId != null) await notes.linkCapture(existing.id, captureId);
    await _linkPeople(existing.id, incoming.people);
    await indexer.indexNote(existing.id);
    return updated;
  }

  /// Applies a confirmed chat proposal.
  Future<NoteRow> applyChatProposal(NoteProposal proposal) async {
    if (proposal.kind == ProposalKind.create) {
      final note = await notes.createNote(
        type: proposal.type ?? NoteType.note,
        title: proposal.title ?? 'Untitled',
        body: proposal.body ?? '',
        tags: proposal.tags ?? const [],
      );
      if (note.type == NoteType.person) {
        await _backfillLinksForPerson(note);
      }
      await indexer.indexNote(note.id);
      return note;
    }

    final id = proposal.noteId;
    if (id == null) {
      throw StateError('An update proposal carried no note id.');
    }
    final updated = await notes.updateNote(
      id: id,
      changeSource: ChangeSource.chatEdit,
      title: proposal.title,
      body: proposal.body,
      tags: proposal.tags,
    );
    await indexer.indexNote(id);
    return updated;
  }

  Future<NoteRow> applyManualEdit({
    required String id,
    NoteType? type,
    String? title,
    String? body,
    List<String>? tags,
  }) async {
    final updated = await notes.updateNote(
      id: id,
      changeSource: ChangeSource.manualEdit,
      type: type,
      title: title,
      body: body,
      tags: tags,
    );
    await indexer.indexNote(id);
    return updated;
  }

  Future<void> delete(String noteId) async {
    // The row cascade removes the links; the embedding is cleared explicitly
    // so a stale vector can never surface in a search.
    await embeddings.deleteForNote(noteId);
    await notes.deleteNote(noteId);
  }

  /// Links a note to the `person` notes for the names the LLM extracted.
  ///
  /// Names with no matching person note are simply skipped — the link appears
  /// later, when that person note is created and back-filled.
  Future<void> _linkPeople(String noteId, List<String> names) async {
    for (final name in names) {
      final person = await notes.findPersonByName(name);
      if (person != null) await notes.linkPerson(noteId, person.id);
    }
  }

  /// When a person note is created, connect the notes that already mention
  /// them by name. Without this, everything recorded before you had a note
  /// about someone stays invisible from their page.
  Future<void> _backfillLinksForPerson(NoteRow person) async {
    final hits = await notes.searchFts(person.title, limit: 50);
    if (hits.isEmpty) return;

    final candidates = await notes.notesByIds(
      [for (final hit in hits) hit.noteId],
    );
    final needle = person.title.trim().toLowerCase();

    for (final candidate in candidates) {
      if (candidate.id == person.id) continue;
      // FTS matches on any term, so confirm the whole name really appears
      // before asserting a link.
      final haystack = '${candidate.title} ${candidate.body}'.toLowerCase();
      if (haystack.contains(needle)) {
        await notes.linkPerson(candidate.id, person.id);
      }
    }
  }
}
