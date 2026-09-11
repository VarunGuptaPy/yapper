import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../notes/note_detail_page.dart';
import '../theme.dart';

/// Renders an assistant answer as Markdown, with `[1]` citation markers turned
/// into inline links that open the note they point at.
///
/// The agent already renumbers markers to 1..n in citation order, so the
/// numbers here line up with the chips underneath.
class ChatMarkdown extends StatelessWidget {
  const ChatMarkdown({
    super.key,
    required this.content,
    this.citations = const [],
  });

  final String content;

  /// Note ids in citation order: `[1]` is `citations[0]`.
  final List<String> citations;

  static const _scheme = 'yapnote';
  static final _marker = RegExp(r'\[(\d{1,3})\]');

  /// Rewrites `[1]` into `[\[1\]](yapnote:<id>)`.
  ///
  /// The brackets are backslash-escaped so the rendered link still reads as
  /// "[1]" rather than a bare digit floating in the sentence.
  String _linkify() {
    if (citations.isEmpty) return content;
    return content.replaceAllMapped(_marker, (match) {
      final index = int.tryParse(match.group(1)!);
      if (index == null || index < 1 || index > citations.length) {
        return match.group(0)!;
      }
      // Not a raw string: the escaped brackets need to survive into the
      // markdown, but $_scheme and the note id must interpolate.
      return '[\\[$index\\]]($_scheme:${citations[index - 1]})';
    });
  }

  void _open(BuildContext context, String? href) {
    if (href == null || !href.startsWith('$_scheme:')) return;
    final id = href.substring(_scheme.length + 1);
    if (id.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final body = theme.textTheme.bodyMedium!.copyWith(height: 1.5);

    return MarkdownBody(
      data: _linkify(),
      selectable: true,
      onTapLink: (text, href, title) => _open(context, href),
      styleSheet: MarkdownStyleSheet(
        p: body,
        pPadding: const EdgeInsets.only(bottom: 2),
        a: body.copyWith(
          color: scheme.primary,
          fontWeight: FontWeight.w700,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        strong: body.copyWith(fontWeight: FontWeight.w700),
        em: body.copyWith(fontStyle: FontStyle.italic),
        listBullet: body,
        listBulletPadding: const EdgeInsets.only(right: 8),
        blockSpacing: 10,
        h1: theme.textTheme.titleLarge,
        h2: theme.textTheme.titleLarge?.copyWith(fontSize: 19),
        h3: theme.textTheme.titleMedium,
        code: TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          height: 1.4,
          backgroundColor: scheme.surfaceContainerHighest,
          color: scheme.onSurface,
        ),
        codeblockDecoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.outlineVariant),
        ),
        codeblockPadding: const EdgeInsets.all(12),
        blockquote: body.copyWith(color: scheme.onSurfaceVariant),
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: context.accents.goal, width: 3),
          ),
        ),
        blockquotePadding: const EdgeInsets.only(left: 12, top: 2, bottom: 2),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: scheme.outlineVariant),
          ),
        ),
      ),
    );
  }
}
