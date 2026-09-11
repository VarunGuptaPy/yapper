import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/errors.dart';
import '../../core/log.dart';
import '../../data/db/connection.dart';
import '../../data/db/database.dart';
import 'backup_crypto.dart';
import 'backup_format.dart';

/// A decrypted, verified backup waiting for the user to confirm the replace.
class PreparedRestore {
  const PreparedRestore({required this.manifest, required this.stagedDb});

  final BackupManifest manifest;

  /// A verified copy on disk. Nothing in the live database has been touched.
  final File stagedDb;
}

class RestoreOutcome {
  const RestoreOutcome({required this.manifest, required this.safetyCopy});

  final BackupManifest manifest;

  /// Where the previous database was parked, in case the restore was a mistake.
  final File safetyCopy;
}

/// Encrypted export and restore of the notes database (SPEC.md §11).
///
/// Audio is deliberately not included: the owner asked for notes only, and
/// recordings are by far the larger half.
class BackupService {
  BackupService({required this.database});

  final AppDatabase database;

  static const fileExtension = 'yapbackup';

  /// Writes an encrypted backup to a temporary file, ready to hand to the
  /// share sheet.
  Future<File> export({
    required String passphrase,
    bool includeEmbeddings = false,
  }) async {
    if (passphrase.trim().length < 8) {
      throw const ValidationException(
        'Use a passphrase of at least 8 characters. '
        'It is the only thing protecting this file.',
      );
    }

    final workDir = await _workDirectory();
    final staged = File(p.join(workDir.path, 'export-${_stamp()}.sqlite'));

    try {
      await _snapshotDatabaseTo(staged);
      if (!includeEmbeddings) await _stripEmbeddings(staged);

      final manifest = await _describe(staged, includeEmbeddings);
      final archive = Archive()
        ..addFile(ArchiveFile.string(
          BackupManifest.manifestEntryName,
          jsonEncode(manifest.toJson()),
        ))
        ..addFile(ArchiveFile.bytes(
          BackupManifest.dbEntryName,
          await staged.readAsBytes(),
        ));

      final zipped = ZipEncoder().encodeBytes(archive);

      // Argon2id plus AES over a few megabytes is far too slow for the UI
      // thread (SPEC.md §3).
      final sealed = await compute(
        encryptBackup,
        EncryptRequest(
          passphrase: passphrase,
          plaintext: Uint8List.fromList(zipped),
        ),
      );

      final out = File(p.join(workDir.path, _suggestedFileName()));
      await out.writeAsBytes(sealed, flush: true);
      logD('Backup', 'wrote ${sealed.length} bytes');
      return out;
    } finally {
      if (await staged.exists()) await staged.delete();
    }
  }

  /// Decrypts and fully validates a backup **without touching live data**.
  Future<PreparedRestore> prepareRestore({
    required File file,
    required String passphrase,
  }) async {
    final bytes = await file.readAsBytes();
    final clear = await compute(
      decryptBackup,
      DecryptRequest(passphrase: passphrase, fileBytes: bytes),
    );

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(clear);
    } catch (_) {
      throw const ValidationException('This backup could not be unpacked.');
    }

    final manifestEntry = _entry(archive, BackupManifest.manifestEntryName);
    final dbEntry = _entry(archive, BackupManifest.dbEntryName);

    final BackupManifest manifest;
    try {
      manifest = BackupManifest.fromJson(
        jsonDecode(utf8.decode(manifestEntry.content)) as Map<String, dynamic>,
      );
    } catch (_) {
      throw const ValidationException('This backup has a damaged manifest.');
    }

    if (manifest.schemaVersion > database.schemaVersion) {
      throw ValidationException(
        'This backup came from a newer version of Yap '
        '(database v${manifest.schemaVersion}). Update the app first.',
      );
    }

    final workDir = await _workDirectory();
    final staged = File(p.join(workDir.path, 'restore-${_stamp()}.sqlite'));
    await staged.writeAsBytes(dbEntry.content, flush: true);

    await _verifyDatabase(staged);
    return PreparedRestore(manifest: manifest, stagedDb: staged);
  }

  /// Swaps the verified database in, keeping the old one as a safety copy.
  ///
  /// The caller must close the live database first and reopen it afterwards —
  /// this method only moves files.
  Future<RestoreOutcome> applyRestore(PreparedRestore prepared) async {
    final livePath = await appDatabasePath();
    final live = File(livePath);

    final safety = File('$livePath.before-restore-${_stamp()}');
    if (await live.exists()) {
      await live.copy(safety.path);
    }

    // The write-ahead log and shared-memory files belong to the old database.
    // Leaving them behind lets SQLite replay stale pages over the new file.
    for (final suffix in ['-wal', '-shm']) {
      final sidecar = File('$livePath$suffix');
      if (await sidecar.exists()) await sidecar.delete();
    }

    await prepared.stagedDb.copy(livePath);
    await prepared.stagedDb.delete();

    logD('Backup', 'restore applied, safety copy kept');
    return RestoreOutcome(manifest: prepared.manifest, safetyCopy: safety);
  }

  /// Folds the write-ahead log back into the main file and copies it, so the
  /// snapshot is complete on its own.
  Future<void> _snapshotDatabaseTo(File target) async {
    await database.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    final live = File(await appDatabasePath());
    if (!await live.exists()) {
      throw const ApiException('There is no database to back up yet.');
    }
    await live.copy(target.path);
  }

  /// Embeddings are regenerated from the notes, and at roughly 6 KB per note
  /// they dominate the file. Dropping them keeps a backup small enough to
  /// email to yourself.
  Future<void> _stripEmbeddings(File dbFile) async {
    final db = AppDatabase(NativeDatabase(dbFile));
    try {
      await db.customStatement('DELETE FROM embeddings');
      await db.customStatement('VACUUM');
    } finally {
      await db.close();
    }
  }

  Future<BackupManifest> _describe(File dbFile, bool embeddingsIncluded) async {
    final db = AppDatabase(NativeDatabase(dbFile));
    try {
      Future<int> count(String table) async {
        final rows =
            await db.customSelect('SELECT COUNT(*) AS c FROM $table').get();
        return rows.single.read<int>('c');
      }

      return BackupManifest(
        schemaVersion: db.schemaVersion,
        createdAt: DateTime.now(),
        noteCount: await count('notes'),
        captureCount: await count('captures'),
        embeddingsIncluded: embeddingsIncluded,
      );
    } finally {
      await db.close();
    }
  }

  /// Opens the candidate and satisfies itself that it is a real, intact Yap
  /// database before anything irreversible happens.
  Future<void> _verifyDatabase(File dbFile) async {
    final db = AppDatabase(NativeDatabase(dbFile));
    try {
      final integrity =
          await db.customSelect('PRAGMA integrity_check').get();
      final verdict = integrity.isEmpty
          ? 'empty'
          : integrity.first.data.values.first.toString();
      if (verdict != 'ok') {
        throw const ValidationException(
          'This backup\'s database failed its integrity check.',
        );
      }

      // Opening is not enough: a valid SQLite file from another app would pass
      // integrity_check happily.
      for (final table in ['notes', 'captures', 'note_versions']) {
        await db.customSelect('SELECT COUNT(*) FROM $table').get();
      }
      await db.customSelect('SELECT note_id FROM notes_fts LIMIT 1').get();
    } on ValidationException {
      rethrow;
    } catch (e) {
      throw ValidationException(
        'This file is not a usable Yap database.',
        cause: e,
      );
    } finally {
      await db.close();
    }
  }

  ArchiveFile _entry(Archive archive, String name) {
    for (final file in archive.files) {
      if (file.name == name && file.isFile) return file;
    }
    throw ValidationException('This backup is missing $name.');
  }

  static String _stamp() => DateTime.now()
      .toIso8601String()
      .replaceAll(RegExp(r'[:.]'), '-')
      .split('T')
      .join('_');

  static String _suggestedFileName() => 'yap-${_stamp()}.$fileExtension';

  Future<Directory> _workDirectory() async {
    final base = await getTemporaryDirectory();
    final dir = Directory(p.join(base.path, 'backup'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}
