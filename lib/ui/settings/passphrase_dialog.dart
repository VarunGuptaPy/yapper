import 'package:flutter/material.dart';

/// Asks for a passphrase.
///
/// On export it asks twice: this passphrase is the only thing standing between
/// the file and whoever finds it, and there is no way to recover it, so a typo
/// would quietly produce an unopenable backup.
class PassphraseDialog extends StatefulWidget {
  const PassphraseDialog({
    super.key,
    required this.title,
    required this.actionLabel,
    this.message,
    this.confirm = false,
  });

  final String title;
  final String actionLabel;
  final String? message;
  final bool confirm;

  static Future<String?> show(
    BuildContext context, {
    required String title,
    required String actionLabel,
    String? message,
    bool confirm = false,
  }) =>
      showDialog<String>(
        context: context,
        builder: (_) => PassphraseDialog(
          title: title,
          actionLabel: actionLabel,
          message: message,
          confirm: confirm,
        ),
      );

  @override
  State<PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<PassphraseDialog> {
  final _first = TextEditingController();
  final _second = TextEditingController();
  bool _obscured = true;
  String? _error;

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _first.text;
    if (value.trim().length < 8) {
      setState(() => _error = 'Use at least 8 characters.');
      return;
    }
    if (widget.confirm && value != _second.text) {
      setState(() => _error = 'The two passphrases do not match.');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.message != null) ...[
            Text(widget.message!, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 16),
          ],
          TextField(
            controller: _first,
            autofocus: true,
            obscureText: _obscured,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Passphrase',
              suffixIcon: IconButton(
                icon: Icon(_obscured
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined),
                onPressed: () => setState(() => _obscured = !_obscured),
              ),
            ),
            onSubmitted: (_) => widget.confirm ? null : _submit(),
          ),
          if (widget.confirm) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _second,
              obscureText: _obscured,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: 'Repeat it'),
              onSubmitted: (_) => _submit(),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.actionLabel)),
      ],
    );
  }
}
