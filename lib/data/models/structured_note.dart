import 'dart:convert';

import '../../core/errors.dart';
import 'enums.dart';

/// One note proposed by the structuring LLM, before the user reviews it.
class StructuredNote {
  const StructuredNote({
    required this.type,
    required this.title,
    required this.body,
    required this.tags,
    required this.people,
    this.mergeTargetId,
    this.mergeReason,
  });

  final NoteType type;
  final String title;
  final String body;
  final List<String> tags;

  /// Names exactly as spoken. Phase 3 turns these into `note_people` links.
  final List<String> people;

  /// Set by the LLM when this thought extends an existing note.
  /// Phase 1 parses it but the review card ignores it — merge lands in Phase 3.
  final String? mergeTargetId;
  final String? mergeReason;

  StructuredNote copyWith({
    NoteType? type,
    String? title,
    String? body,
    List<String>? tags,
  }) =>
      StructuredNote(
        type: type ?? this.type,
        title: title ?? this.title,
        body: body ?? this.body,
        tags: tags ?? this.tags,
        people: people,
        mergeTargetId: mergeTargetId,
        mergeReason: mergeReason,
      );
}

/// Matches any character in the Devanagari block. The structuring prompt
/// requires Roman script, so its presence means the model ignored the rules and
/// the retry should say so explicitly.
final _devanagari = RegExp(r'[ऀ-ॿ]');

/// Strictly validates the structuring response described in SPEC.md §7.1.
///
/// Throws [ValidationException] with a message precise enough to hand straight
/// back to the model on the retry attempt.
class StructuredNoteParser {
  const StructuredNoteParser();

  /// Parses raw model output. Tolerates a ```json fence, because plenty of
  /// OpenAI-compatible providers add one even in JSON mode; everything past
  /// that is strict.
  List<StructuredNote> parse(String raw) {
    final cleaned = _stripFence(raw).trim();
    if (cleaned.isEmpty) {
      throw const ValidationException('Response was empty; expected a JSON object.');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(cleaned);
    } on FormatException catch (e) {
      throw ValidationException('Response is not valid JSON: ${e.message}', cause: e);
    }

    if (decoded is! Map<String, dynamic>) {
      throw const ValidationException(
        'Top level must be a JSON object with a "notes" key.',
      );
    }

    final notesField = decoded['notes'];
    if (notesField == null) {
      throw const ValidationException('Missing required key "notes".');
    }
    if (notesField is! List) {
      throw const ValidationException('"notes" must be an array.');
    }
    if (notesField.isEmpty) {
      throw const ValidationException(
        '"notes" was empty; return at least one note for the transcript.',
      );
    }

    return [
      for (var i = 0; i < notesField.length; i++)
        _parseNote(notesField[i], i),
    ];
  }

  StructuredNote _parseNote(Object? raw, int index) {
    final where = 'notes[$index]';
    if (raw is! Map<String, dynamic>) {
      throw ValidationException('$where must be a JSON object.');
    }

    final typeRaw = raw['type'];
    if (typeRaw is! String) {
      throw ValidationException('$where.type is required and must be a string.');
    }
    final type = NoteType.tryParse(typeRaw);
    if (type == null) {
      throw ValidationException(
        '$where.type was "$typeRaw"; must be one of '
        '${NoteType.values.map((t) => t.name).join(', ')}.',
      );
    }

    final title = _requiredString(raw['title'], '$where.title');
    final body = _requiredString(raw['body'], '$where.body');
    final tags = _stringList(raw['tags'], '$where.tags');
    final people = _stringList(raw['people'], '$where.people');

    _rejectDevanagari(title, '$where.title');
    _rejectDevanagari(body, '$where.body');
    for (var t = 0; t < tags.length; t++) {
      _rejectDevanagari(tags[t], '$where.tags[$t]');
    }

    final mergeTargetId = _nullableString(raw['merge_target_id'], '$where.merge_target_id');
    final mergeReason = _nullableString(raw['merge_reason'], '$where.merge_reason');

    return StructuredNote(
      type: type,
      title: title,
      body: body,
      tags: tags,
      people: people,
      mergeTargetId: mergeTargetId,
      mergeReason: mergeReason,
    );
  }

  String _requiredString(Object? value, String where) {
    if (value is! String) {
      throw ValidationException('$where is required and must be a string.');
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw ValidationException('$where must not be empty.');
    }
    return trimmed;
  }

  String? _nullableString(Object? value, String where) {
    if (value == null) return null;
    if (value is! String) {
      throw ValidationException('$where must be a string or null.');
    }
    final trimmed = value.trim();
    // Models like to write the literal word "null" inside a string.
    if (trimmed.isEmpty || trimmed.toLowerCase() == 'null') return null;
    return trimmed;
  }

  List<String> _stringList(Object? value, String where) {
    if (value == null) return const [];
    if (value is! List) {
      throw ValidationException('$where must be an array of strings.');
    }
    final out = <String>[];
    for (var i = 0; i < value.length; i++) {
      final item = value[i];
      if (item is! String) {
        throw ValidationException('$where[$i] must be a string.');
      }
      final trimmed = item.trim();
      if (trimmed.isNotEmpty) out.add(trimmed);
    }
    return out;
  }

  void _rejectDevanagari(String value, String where) {
    if (_devanagari.hasMatch(value)) {
      throw ValidationException(
        '$where contains Devanagari script. Rewrite it in English or '
        'Roman-script Hinglish.',
      );
    }
  }

  String _stripFence(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith('```')) return trimmed;
    final firstNewline = trimmed.indexOf('\n');
    if (firstNewline == -1) return trimmed;
    var inner = trimmed.substring(firstNewline + 1);
    final closing = inner.lastIndexOf('```');
    if (closing != -1) inner = inner.substring(0, closing);
    return inner;
  }
}
