import 'package:drift/drift.dart';

import 'converters.dart';

/// One recording and its journey through the pipeline.
///
/// Rows are never deleted automatically: the audio file and [rawTranscript] are
/// the source of truth (SPEC.md §6).
@DataClassName('CaptureRow')
class Captures extends Table {
  TextColumn get id => text()();
  TextColumn get audioPath => text()();
  IntColumn get durationMs => integer()();
  TextColumn get rawTranscript => text().nullable()();
  TextColumn get status => text().map(const CaptureStatusConverter())();
  TextColumn get error => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('NoteRow')
class Notes extends Table {
  TextColumn get id => text()();
  TextColumn get type => text().map(const NoteTypeConverter())();
  TextColumn get title => text()();
  TextColumn get body => text()();
  TextColumn get tags => text().map(const TagsConverter())();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// A snapshot of a note taken immediately before it was changed.
@DataClassName('NoteVersionRow')
class NoteVersions extends Table {
  TextColumn get id => text()();
  TextColumn get noteId =>
      text().references(Notes, #id, onDelete: KeyAction.cascade)();
  TextColumn get title => text()();
  TextColumn get body => text()();
  TextColumn get tags => text().map(const TagsConverter())();
  DateTimeColumn get changedAt => dateTime()();
  TextColumn get changeSource => text().map(const ChangeSourceConverter())();

  @override
  Set<Column> get primaryKey => {id};
}

/// Which recordings contributed to a note.
@DataClassName('NoteCaptureRow')
class NoteCaptures extends Table {
  TextColumn get noteId =>
      text().references(Notes, #id, onDelete: KeyAction.cascade)();
  TextColumn get captureId =>
      text().references(Captures, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {noteId, captureId};
}

/// Links a note to the `person` notes it mentions. Populated in Phase 3.
@DataClassName('NotePersonRow')
class NotePeople extends Table {
  // Both columns point at `notes`, so each needs its own reference name for
  // drift to generate unambiguous filters.
  @ReferenceName('mentioningNotes')
  TextColumn get noteId =>
      text().references(Notes, #id, onDelete: KeyAction.cascade)();
  @ReferenceName('mentionedInNotes')
  TextColumn get personNoteId =>
      text().references(Notes, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {noteId, personNoteId};
}

/// One vector per note per embedding model. Written from Phase 2 onward; the
/// table ships in schema v1 so no migration is needed to start using it.
@DataClassName('EmbeddingRow')
class Embeddings extends Table {
  TextColumn get noteId =>
      text().references(Notes, #id, onDelete: KeyAction.cascade)();
  TextColumn get modelId => text()();
  IntColumn get dims => integer()();
  BlobColumn get vector => blob()();

  @override
  Set<Column> get primaryKey => {noteId, modelId};
}

/// One chat thread. Starting a fresh chat opens a new one rather than wiping
/// what came before, so old conversations stay browsable.
@DataClassName('ChatConversationRow')
class ChatConversations extends Table {
  TextColumn get id => text()();

  /// Taken from the opening question. Null until the first message is sent.
  TextColumn get title => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  /// Bumped on every message so the list sorts by recent activity.
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Chat turns, kept locally like everything else (SPEC.md §9).
///
/// Only the turns the user sees are stored: intermediate tool rounds are
/// replayed from the notes themselves rather than persisted.
@DataClassName('ChatMessageRow')
class ChatMessages extends Table {
  TextColumn get id => text()();

  TextColumn get conversationId =>
      text().references(ChatConversations, #id, onDelete: KeyAction.cascade)();

  /// `user` or `assistant`.
  TextColumn get role => text()();
  TextColumn get content => text()();

  /// Note ids this answer cited, as a JSON array. Rendered as tappable chips.
  TextColumn get citations => text().map(const TagsConverter())();

  /// A pending `propose_create_note` / `propose_update_note` payload, as JSON.
  /// Null on ordinary turns.
  TextColumn get proposal => text().nullable()();

  /// `pending`, `confirmed` or `dismissed`; null when there is no proposal.
  TextColumn get proposalStatus => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}
