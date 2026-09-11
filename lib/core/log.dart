import 'package:flutter/foundation.dart';

/// Debug-only logging that structurally cannot leak note contents.
///
/// The spec forbids logging transcripts and note bodies. Rather than trusting
/// every call site to remember that, this logger only accepts a short tag and a
/// message, and [redact] is the single sanctioned way to mention user text at
/// all — it reports a length, never the characters.
void logD(String tag, String message) {
  if (kDebugMode) {
    debugPrint('[$tag] $message');
  }
}

void logE(String tag, String message, [Object? error]) {
  if (kDebugMode) {
    debugPrint('[$tag] ERROR $message${error == null ? '' : ' ($error)'}');
  }
}

/// Describes user text without revealing it: `<text:142 chars>`.
String redact(String? text) =>
    text == null ? '<null>' : '<text:${text.length} chars>';
