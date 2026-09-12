import '../../data/db/database.dart';

/// The structuring system prompt, verbatim from SPEC.md §7.1.
const structuringSystemPrompt = '''
You convert a raw voice transcript, often Hindi-English code-mixed, into structured notes for the speaker's personal knowledge base.
Rules:
- Write title, body, and tags in English or Roman-script Hinglish. Never use Devanagari.
- Remove filler words and repetition, but keep every concrete detail: names, places, numbers, reasons, and the speaker's intent and tone.
- Never invent facts that aren't in the transcript.
- One transcript can contain several unrelated thoughts; return one note per distinct thought.
- type is one of: idea, person, rule, goal, note. A "person" note is about a specific individual: who they are, how they met, what they're good at, how they could help.
- List any people mentioned in `people` (names as spoken).
- You're given candidate existing notes. Set `merge_target_id` only if the new thought clearly extends or refines that exact note; otherwise null.
Return ONLY JSON matching the schema.

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
''';

/// Builds the user turn: the candidate notes the transcript might extend,
/// followed by the transcript itself.
///
/// Phase 1 always passes an empty candidate list — matching needs embeddings,
/// which arrive in Phase 2.
String buildStructuringUserPrompt({
  required String transcript,
  List<NoteRow> candidates = const [],
  List<String> knownPeople = const [],
}) {
  final buffer = StringBuffer();

  // Correcting known names belongs here, not in the speech recogniser.
  // Sarvam's keyterm biasing is phonetic and blind: it replaced "Madaari"
  // with "Parvesh Rawal" because a name was in its bias list. The model
  // reading the whole sentence can tell a film title from a person, so the
  // roster is given to it with an explicit instruction not to force a match.
  if (knownPeople.isNotEmpty) {
    buffer.writeln('People the speaker already has notes about:');
    for (final name in knownPeople) {
      buffer.writeln('- $name');
    }
    buffer
      ..writeln()
      ..writeln(
        'Use these spellings when the transcript clearly means one of these '
        'people — speech recognition often mangles a name. Do NOT replace any '
        'other name, title or word with one of them. If what was said is not '
        'one of these people, keep it exactly as transcribed.',
      )
      ..writeln();
  }

  buffer.writeln('Candidate existing notes:');
  if (candidates.isEmpty) {
    buffer.writeln('(none)');
  } else {
    for (final note in candidates) {
      buffer.writeln('- id: ${note.id}');
      buffer.writeln('  type: ${note.type.name}');
      buffer.writeln('  title: ${note.title}');
      buffer.writeln('  body: ${note.body}');
      if (note.tags.isNotEmpty) {
        buffer.writeln('  tags: ${note.tags.join(', ')}');
      }
    }
  }

  buffer
    ..writeln()
    ..writeln('Transcript:')
    ..writeln(transcript);

  return buffer.toString();
}

/// The follow-up turn used for the single retry, carrying the exact validation
/// failure so the model can correct it rather than guess.
String buildRetryPrompt(String validationError) =>
    'Your previous response was rejected: $validationError\n'
    'Return ONLY corrected JSON matching the schema. No prose, no code fence.';
