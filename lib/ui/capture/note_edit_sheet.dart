import 'package:flutter/material.dart';

import '../../data/models/enums.dart';

/// The edited result of a note or proposal.
class NoteDraft {
  const NoteDraft({
    required this.type,
    required this.title,
    required this.body,
    required this.tags,
  });

  final NoteType type;
  final String title;
  final String body;
  final List<String> tags;
}

/// Full-screen editor used both for "Edit" on a review card and for manual
/// edits on an existing note.
class NoteEditSheet extends StatefulWidget {
  const NoteEditSheet({
    super.key,
    required this.initial,
    required this.heading,
    required this.saveLabel,
  });

  final NoteDraft initial;
  final String heading;
  final String saveLabel;

  /// Returns the edited draft, or null if the user backed out.
  static Future<NoteDraft?> show(
    BuildContext context, {
    required NoteDraft initial,
    required String heading,
    String saveLabel = 'Save',
  }) {
    return Navigator.of(context).push<NoteDraft>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => NoteEditSheet(
          initial: initial,
          heading: heading,
          saveLabel: saveLabel,
        ),
      ),
    );
  }

  @override
  State<NoteEditSheet> createState() => _NoteEditSheetState();
}

class _NoteEditSheetState extends State<NoteEditSheet> {
  late final TextEditingController _title =
      TextEditingController(text: widget.initial.title);
  late final TextEditingController _body =
      TextEditingController(text: widget.initial.body);
  late final TextEditingController _tags =
      TextEditingController(text: widget.initial.tags.join(', '));
  late NoteType _type = widget.initial.type;

  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _tags.dispose();
    super.dispose();
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    Navigator.of(context).pop(
      NoteDraft(
        type: _type,
        title: _title.text.trim(),
        body: _body.text.trim(),
        tags: _tags.text
            .split(',')
            .map((t) => t.trim())
            .where((t) => t.isNotEmpty)
            .toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.heading),
        actions: [
          TextButton(onPressed: _save, child: Text(widget.saveLabel)),
          const SizedBox(width: 8),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            Wrap(
              spacing: 8,
              children: [
                for (final type in NoteType.values)
                  ChoiceChip(
                    label: Text(type.label),
                    selected: _type == type,
                    onSelected: (_) => setState(() => _type = type),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _title,
              decoration: const InputDecoration(labelText: 'Title'),
              textCapitalization: TextCapitalization.sentences,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Give it a title' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _body,
              decoration: const InputDecoration(labelText: 'Body'),
              minLines: 6,
              maxLines: 20,
              textCapitalization: TextCapitalization.sentences,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Body cannot be empty' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _tags,
              decoration: const InputDecoration(
                labelText: 'Tags',
                helperText: 'Comma separated',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
