import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Recordings live at `<app docs>/audio/<uuid>.m4a` (SPEC.md §7.1) and are
/// never deleted automatically — they are the source of truth.
class AudioPaths {
  const AudioPaths();

  Future<Directory> audioDirectory() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'audio'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<String> pathForCapture(String captureId) async {
    final dir = await audioDirectory();
    return p.join(dir.path, '$captureId.m4a');
  }

  /// Resolves a stored path against the current documents directory.
  ///
  /// iOS rewrites the app container path on every install and some Android
  /// updates move it too, so an absolute path recorded weeks ago can be stale
  /// while the file itself is still there under the same name.
  Future<File> resolve(String storedPath) async {
    final direct = File(storedPath);
    if (await direct.exists()) return direct;

    final dir = await audioDirectory();
    return File(p.join(dir.path, p.basename(storedPath)));
  }
}
