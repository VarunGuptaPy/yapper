import 'dart:convert';

import '../../data/models/enums.dart';

enum ProposalKind { create, update, delete }

/// A change the chat agent suggested. Nothing is written until the user taps
/// Confirm on the card (SPEC.md §9).
class NoteProposal {
  const NoteProposal({
    required this.kind,
    this.noteId,
    this.type,
    this.title,
    this.body,
    this.tags,
    this.reason,
  });

  final ProposalKind kind;

  /// Set for [ProposalKind.update] and [ProposalKind.delete].
  final String? noteId;

  final NoteType? type;
  final String? title;
  final String? body;

  /// Null means "leave the existing tags alone" on an update.
  final List<String>? tags;

  final String? reason;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        if (noteId != null) 'note_id': noteId,
        if (type != null) 'type': type!.name,
        if (title != null) 'title': title,
        if (body != null) 'body': body,
        if (tags != null) 'tags': tags,
        if (reason != null) 'reason': reason,
      };

  String encode() => jsonEncode(toJson());

  static NoteProposal? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map<String, dynamic>) return null;
      final tags = map['tags'];
      return NoteProposal(
        kind: switch (map['kind']) {
          'update' => ProposalKind.update,
          'delete' => ProposalKind.delete,
          _ => ProposalKind.create,
        },
        noteId: map['note_id'] as String?,
        type: map['type'] is String ? NoteType.tryParse(map['type'] as String) : null,
        title: map['title'] as String?,
        body: map['body'] as String?,
        tags: tags is List ? [for (final t in tags) if (t is String) t] : null,
        reason: map['reason'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Whether a proposal card is still actionable.
enum ProposalStatus {
  pending,
  confirmed,
  dismissed;

  static ProposalStatus fromWire(String? value) => switch (value) {
        'confirmed' => ProposalStatus.confirmed,
        'dismissed' => ProposalStatus.dismissed,
        _ => ProposalStatus.pending,
      };
}
