import 'dart:convert';

import '../../core/errors.dart';
import '../../data/db/database.dart';
import '../../data/models/structured_note.dart';
import '../llm/llm_models.dart';
import '../llm/llm_service.dart';

/// The result of merging a new thought into an existing note.
class MergedNote {
  const MergedNote({
    required this.title,
    required this.body,
    required this.tags,
  });

  final String title;
  final String body;
  final List<String> tags;
}

const _mergeSystemPrompt = '''
You merge a new thought into an existing note in the speaker's personal knowledge base.

Rules:
- Keep EVERY concrete detail from both the existing note and the new thought: names, places, numbers, reasons, intent and tone. Losing a detail is the worst possible outcome.
- Remove only exact duplication and filler. If the two sources disagree, keep both and say which is newer.
- Do not invent anything that is in neither source.
- Write in English or Roman-script Hinglish. Never use Devanagari.
- Keep the existing title unless the new thought clearly changes what the note is about.
- Merge the tag lists, removing duplicates.

Return ONLY JSON: {"title": "string", "body": "string", "tags": ["string"]}
''';

/// Produces the merged body when a capture extends an existing note
/// (SPEC.md §7.5).
class MergeService {
  MergeService(this._llm);

  final LlmService _llm;

  Future<MergedNote> merge({
    required NoteRow existing,
    required StructuredNote incoming,
  }) async {
    final user = StringBuffer()
      ..writeln('Existing note:')
      ..writeln('title: ${existing.title}')
      ..writeln('body: ${existing.body}')
      ..writeln('tags: ${existing.tags.join(', ')}')
      ..writeln()
      ..writeln('New thought:')
      ..writeln('title: ${incoming.title}')
      ..writeln('body: ${incoming.body}')
      ..writeln('tags: ${incoming.tags.join(', ')}');

    final response = await _llm.complete(
      [
        const ChatMessage.system(_mergeSystemPrompt),
        ChatMessage.user(user.toString()),
      ],
      jsonMode: true,
    );

    return _parse(response.content ?? '', existing: existing, incoming: incoming);
  }

  MergedNote _parse(
    String raw, {
    required NoteRow existing,
    required StructuredNote incoming,
  }) {
    final cleaned = _stripFence(raw).trim();
    Object? decoded;
    try {
      decoded = jsonDecode(cleaned);
    } catch (_) {
      decoded = null;
    }

    if (decoded is! Map<String, dynamic>) {
      throw const ValidationException(
        'The model did not return a valid merged note.',
      );
    }

    final body = decoded['body'];
    if (body is! String || body.trim().isEmpty) {
      throw const ValidationException('The merged note had no body.');
    }
    if (RegExp(r'[ऀ-ॿ]').hasMatch(body)) {
      throw const ValidationException(
        'The merged note contains Devanagari script.',
      );
    }

    final title = decoded['title'];
    final rawTags = decoded['tags'];

    // Merging the tags locally as a floor: even if the model drops some, no
    // tag that existed before the merge is lost.
    final tags = <String>[];
    final seen = <String>{};
    for (final tag in [
      if (rawTags is List)
        for (final t in rawTags)
          if (t is String) t,
      ...existing.tags,
      ...incoming.tags,
    ]) {
      final trimmed = tag.trim();
      if (trimmed.isEmpty) continue;
      if (seen.add(trimmed.toLowerCase())) tags.add(trimmed);
    }

    return MergedNote(
      title: title is String && title.trim().isNotEmpty
          ? title.trim()
          : existing.title,
      body: body.trim(),
      tags: tags,
    );
  }

  String _stripFence(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith('```')) return trimmed;
    final newline = trimmed.indexOf('\n');
    if (newline == -1) return trimmed;
    var inner = trimmed.substring(newline + 1);
    final closing = inner.lastIndexOf('```');
    if (closing != -1) inner = inner.substring(0, closing);
    return inner;
  }
}
