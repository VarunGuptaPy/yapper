import 'dart:convert';

import '../../data/db/database.dart';
import '../../data/models/enums.dart';
import '../../data/repositories/note_repository.dart';
import '../../search/hybrid_search.dart';
import '../llm/llm_models.dart';
import 'note_proposal.dart';

/// What one tool call produced.
class ToolOutcome {
  const ToolOutcome(this.resultJson, {this.proposal});

  /// Fed back to the model as the `tool` message.
  final String resultJson;

  /// Set when the model called a `propose_*` tool.
  final NoteProposal? proposal;
}

/// The read and propose tools from SPEC.md §9, plus the bookkeeping that maps
/// notes to the short reference numbers used for citations.
class ChatToolRunner {
  ChatToolRunner({required this.notes, required this.search});

  final NoteRepository notes;
  final HybridSearch search;

  /// Reference number -> note id, assigned in the order notes first appear.
  final _refToNote = <int, String>{};
  final _noteToRef = <String, int>{};

  Map<int, String> get references => Map.unmodifiable(_refToNote);

  int _refFor(String noteId) {
    final existing = _noteToRef[noteId];
    if (existing != null) return existing;
    final ref = _refToNote.length + 1;
    _refToNote[ref] = noteId;
    _noteToRef[noteId] = ref;
    return ref;
  }

  static final _marker = RegExp(r'\[(\d{1,3})\]');

  /// Rewrites the answer's `[n]` markers to 1..n in order of first appearance,
  /// and returns the note ids they now point at.
  ///
  /// The model's own numbers come from a tool-call session that does not
  /// survive an app restart, and markers for notes it never actually read are
  /// dropped. Renumbering makes the text and the citation chips agree
  /// permanently, since the chips are numbered by position in this list.
  ({String text, List<String> noteIds}) normalizeCitations(String answer) {
    final ids = <String>[];
    final renumbered = answer.replaceAllMapped(_marker, (match) {
      final ref = int.tryParse(match.group(1)!);
      final noteId = ref == null ? null : _refToNote[ref];
      // A marker for a note the model never read is not a citation.
      if (noteId == null) return match.group(0)!;

      var index = ids.indexOf(noteId);
      if (index == -1) {
        ids.add(noteId);
        index = ids.length - 1;
      }
      return '[${index + 1}]';
    });
    return (text: renumbered, noteIds: ids);
  }

  static List<ToolDefinition> definitions({bool allowWrites = true}) => [
        const ToolDefinition(
          name: 'search_notes',
          description:
              'Search the notes by meaning and keyword. Use this before '
              'answering anything about the speaker.',
          parameters: {
            'type': 'object',
            'properties': {
              'query': {'type': 'string', 'description': 'What to look for.'},
              'types': {
                'type': 'array',
                'items': {
                  'type': 'string',
                  'enum': ['idea', 'person', 'rule', 'goal', 'note'],
                },
                'description': 'Optional. Restrict to these note types.',
              },
              'tags': {
                'type': 'array',
                'items': {'type': 'string'},
                'description': 'Optional. Restrict to notes with any of these tags.',
              },
              'limit': {'type': 'integer', 'description': 'Default 8, max 20.'},
            },
            'required': ['query'],
          },
        ),
        const ToolDefinition(
          name: 'list_notes',
          description:
              'List notes of one type, newest first. Use when the speaker asks '
              'for all of something rather than about a topic.',
          parameters: {
            'type': 'object',
            'properties': {
              'type': {
                'type': 'string',
                'enum': ['idea', 'person', 'rule', 'goal', 'note'],
              },
              'limit': {'type': 'integer', 'description': 'Default 20, max 50.'},
            },
            'required': ['type'],
          },
        ),
        const ToolDefinition(
          name: 'get_note',
          description:
              'Read one note in full, with the people it mentions and the '
              'notes that mention it.',
          parameters: {
            'type': 'object',
            'properties': {
              'id': {'type': 'string'},
            },
            'required': ['id'],
          },
        ),
        if (allowWrites) ...[
          const ToolDefinition(
            name: 'propose_create_note',
            description:
                'Propose a new note. Does not save — the speaker confirms it.',
            parameters: {
              'type': 'object',
              'properties': {
                'type': {
                  'type': 'string',
                  'enum': ['idea', 'person', 'rule', 'goal', 'note'],
                },
                'title': {'type': 'string'},
                'body': {'type': 'string'},
                'tags': {
                  'type': 'array',
                  'items': {'type': 'string'},
                },
              },
              'required': ['type', 'title', 'body'],
            },
          ),
          const ToolDefinition(
            name: 'propose_update_note',
            description:
                'Propose a change to an existing note. Does not save — the '
                'speaker confirms it. Pass the complete new body, not a diff.',
            parameters: {
              'type': 'object',
              'properties': {
                'id': {'type': 'string'},
                'new_title': {'type': 'string'},
                'new_body': {'type': 'string'},
                'new_tags': {
                  'type': 'array',
                  'items': {'type': 'string'},
                },
                'reason': {
                  'type': 'string',
                  'description': 'Why this change, in one short sentence.',
                },
              },
              'required': ['id', 'reason'],
            },
          ),
        ],
      ];

  Future<ToolOutcome> run(ToolCall call) async {
    final Map<String, dynamic> args;
    try {
      final decoded = jsonDecode(
        call.argumentsJson.trim().isEmpty ? '{}' : call.argumentsJson,
      );
      args = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return ToolOutcome(_error('Arguments were not valid JSON.'));
    }

    try {
      return switch (call.name) {
        'search_notes' => await _searchNotes(args),
        'list_notes' => await _listNotes(args),
        'get_note' => await _getNote(args),
        'propose_create_note' => _proposeCreate(args),
        'propose_update_note' => await _proposeUpdate(args),
        _ => ToolOutcome(_error('Unknown tool "${call.name}".')),
      };
    } catch (e) {
      return ToolOutcome(_error('The tool failed: $e'));
    }
  }

  Future<ToolOutcome> _searchNotes(Map<String, dynamic> args) async {
    final query = args['query'];
    if (query is! String || query.trim().isEmpty) {
      return ToolOutcome(_error('query is required.'));
    }

    final results = await search.search(
      query,
      filters: SearchFilters(
        types: _types(args['types']),
        tags: _strings(args['tags']),
      ),
      limit: _clampInt(args['limit'], fallback: 8, max: 20),
    );

    return ToolOutcome(jsonEncode({
      'query': query,
      'count': results.length,
      'notes': [for (final r in results) _summary(r.note)],
      if (results.isEmpty)
        'hint': 'Nothing matched. Try one differently-worded search; if that '
            'is also empty, tell the speaker it is not in their notes and '
            'stop. Do not answer from general knowledge.',
    }));
  }

  Future<ToolOutcome> _listNotes(Map<String, dynamic> args) async {
    final typeName = args['type'];
    final type = typeName is String ? NoteType.tryParse(typeName) : null;
    if (type == null) {
      return ToolOutcome(_error(
        'type must be one of ${NoteType.values.map((t) => t.name).join(', ')}.',
      ));
    }

    final limit = _clampInt(args['limit'], fallback: 20, max: 50);
    final rows = await notes.watchNotes(type: type).first;
    final capped = rows.length <= limit ? rows : rows.sublist(0, limit);

    return ToolOutcome(jsonEncode({
      'type': type.name,
      'count': capped.length,
      'total': rows.length,
      'notes': [for (final n in capped) _summary(n)],
    }));
  }

  Future<ToolOutcome> _getNote(Map<String, dynamic> args) async {
    final id = args['id'];
    if (id is! String || id.isEmpty) {
      return ToolOutcome(_error('id is required.'));
    }

    final note = await notes.getNote(id);
    if (note == null) {
      return ToolOutcome(_error('No note with that id.'));
    }

    final people = await notes.peopleFor(id);
    final mentionedIn = await notes.notesMentioning(id);

    return ToolOutcome(jsonEncode({
      ..._full(note),
      'people': [for (final p in people) _summary(p)],
      'mentioned_in': [for (final n in mentionedIn) _summary(n)],
    }));
  }

  ToolOutcome _proposeCreate(Map<String, dynamic> args) {
    final type = args['type'] is String
        ? NoteType.tryParse(args['type'] as String)
        : null;
    final title = args['title'];
    final body = args['body'];

    if (type == null) return ToolOutcome(_error('type is invalid.'));
    if (title is! String || title.trim().isEmpty) {
      return ToolOutcome(_error('title is required.'));
    }
    if (body is! String || body.trim().isEmpty) {
      return ToolOutcome(_error('body is required.'));
    }

    final proposal = NoteProposal(
      kind: ProposalKind.create,
      type: type,
      title: title.trim(),
      body: body.trim(),
      tags: _strings(args['tags']),
    );

    return ToolOutcome(
      jsonEncode({
        'status': 'proposed',
        'note': 'Shown to the speaker as a confirmation card. Not saved yet.',
      }),
      proposal: proposal,
    );
  }

  Future<ToolOutcome> _proposeUpdate(Map<String, dynamic> args) async {
    final id = args['id'];
    if (id is! String || id.isEmpty) {
      return ToolOutcome(_error('id is required.'));
    }

    final existing = await notes.getNote(id);
    if (existing == null) {
      return ToolOutcome(_error('No note with that id.'));
    }

    final newTitle = args['new_title'];
    final newBody = args['new_body'];
    final rawTags = args['new_tags'];
    final hasTags = rawTags is List;

    if (newTitle is! String && newBody is! String && !hasTags) {
      return ToolOutcome(
        _error('Nothing to change: pass new_title, new_body or new_tags.'),
      );
    }

    final proposal = NoteProposal(
      kind: ProposalKind.update,
      noteId: id,
      title: newTitle is String && newTitle.trim().isNotEmpty
          ? newTitle.trim()
          : null,
      body: newBody is String && newBody.trim().isNotEmpty ? newBody.trim() : null,
      tags: hasTags ? _strings(rawTags) : null,
      reason: args['reason'] is String ? (args['reason'] as String).trim() : null,
    );

    return ToolOutcome(
      jsonEncode({
        'status': 'proposed',
        'note': 'Shown to the speaker as a confirmation card. Not saved yet.',
      }),
      proposal: proposal,
    );
  }

  /// A compact note for tool output — enough to answer from, with the `ref`
  /// the model should cite and the `id` it needs for get_note.
  Map<String, dynamic> _summary(NoteRow note) => {
        'ref': _refFor(note.id),
        'id': note.id,
        'type': note.type.name,
        'title': note.title,
        'body': note.body,
        if (note.tags.isNotEmpty) 'tags': note.tags,
      };

  Map<String, dynamic> _full(NoteRow note) => {
        ..._summary(note),
        'created_at': note.createdAt.toIso8601String(),
        'updated_at': note.updatedAt.toIso8601String(),
      };

  String _error(String message) => jsonEncode({'error': message});

  List<NoteType> _types(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is String && NoteType.tryParse(item) != null)
          NoteType.tryParse(item)!,
    ];
  }

  List<String> _strings(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is String && item.trim().isNotEmpty) item.trim(),
    ];
  }

  int _clampInt(Object? raw, {required int fallback, required int max}) {
    final value = raw is int ? raw : (raw is num ? raw.toInt() : null);
    if (value == null || value <= 0) return fallback;
    return value > max ? max : value;
  }
}
