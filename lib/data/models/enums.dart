/// Where a capture sits in the pipeline. Stored as the enum name in SQLite.
enum CaptureStatus {
  recorded,
  transcribing,
  structuring,
  awaitingReview,
  saved,
  failed;

  /// The names in the spec use snake_case on the wire.
  String get wire => switch (this) {
        CaptureStatus.awaitingReview => 'awaiting_review',
        _ => name,
      };

  static CaptureStatus fromWire(String value) => switch (value) {
        'recorded' => CaptureStatus.recorded,
        'transcribing' => CaptureStatus.transcribing,
        'structuring' => CaptureStatus.structuring,
        'awaiting_review' => CaptureStatus.awaitingReview,
        'saved' => CaptureStatus.saved,
        'failed' => CaptureStatus.failed,
        _ => throw ArgumentError('Unknown capture status: $value'),
      };

  /// Statuses the pipeline resumer picks back up on app start.
  bool get isInProgress => switch (this) {
        CaptureStatus.recorded ||
        CaptureStatus.transcribing ||
        CaptureStatus.structuring =>
          true,
        _ => false,
      };

  bool get isTerminal => this == CaptureStatus.saved || this == CaptureStatus.failed;
}

enum NoteType {
  idea,
  person,
  rule,
  goal,
  note;

  static NoteType? tryParse(String value) {
    for (final t in NoteType.values) {
      if (t.name == value) return t;
    }
    return null;
  }

  String get label => switch (this) {
        NoteType.idea => 'Idea',
        NoteType.person => 'Person',
        NoteType.rule => 'Rule',
        NoteType.goal => 'Goal',
        NoteType.note => 'Note',
      };
}

/// Why a note version was written. Phase 1 only produces [manualEdit];
/// [voiceMerge] arrives with the merge flow in Phase 3.
enum ChangeSource {
  voiceMerge,
  chatEdit,
  manualEdit;

  String get wire => switch (this) {
        ChangeSource.voiceMerge => 'voice_merge',
        ChangeSource.chatEdit => 'chat_edit',
        ChangeSource.manualEdit => 'manual_edit',
      };

  static ChangeSource fromWire(String value) => switch (value) {
        'voice_merge' => ChangeSource.voiceMerge,
        'chat_edit' => ChangeSource.chatEdit,
        'manual_edit' => ChangeSource.manualEdit,
        _ => throw ArgumentError('Unknown change source: $value'),
      };
}
