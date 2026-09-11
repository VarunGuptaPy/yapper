import 'dart:io';

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:yapapp/services/backup/backup_crypto.dart';
import 'package:yapapp/services/backup/backup_format.dart';
import 'package:yapapp/core/errors.dart';
import 'package:yapapp/data/db/database.dart';
import 'package:yapapp/data/models/enums.dart';
import 'package:yapapp/data/repositories/note_repository.dart';
import 'package:yapapp/services/backup/backup_service.dart';

void main() {
  const slow = Timeout(Duration(minutes: 3));
  const passphrase = 'correct horse battery';

  late Directory work;
  late Directory liveDir;
  late File liveFile;
  late AppDatabase db;
  late NoteRepository notes;
  late BackupService backup;

  /// A real on-disk database, the way the app has one.
  AppDatabase openLive() => AppDatabase(NativeDatabase(liveFile));

  BackupService serviceFor(AppDatabase database) => BackupService(
        database: database,
        databasePath: () async => liveFile.path,
        workDirectory: () async => work,
      );

  setUp(() async {
    work = await Directory.systemTemp.createTemp('yap_backup_work');
    liveDir = await Directory.systemTemp.createTemp('yap_backup_live');
    liveFile = File('${liveDir.path}/yap.sqlite');
    db = openLive();
    notes = NoteRepository(db);
    backup = serviceFor(db);
  });

  tearDown(() async {
    await db.close();
    if (work.existsSync()) await work.delete(recursive: true);
    if (liveDir.existsSync()) await liveDir.delete(recursive: true);
  });

  Future<void> seed({int count = 3}) async {
    for (var i = 0; i < count; i++) {
      await notes.createNote(
        type: NoteType.values[i % NoteType.values.length],
        title: 'Note $i',
        body: 'Body of note $i, with a detail worth keeping.',
        tags: ['tag$i'],
      );
    }
  }

  group('export', () {
    test('writes an encrypted file naming its own extension', () async {
      await seed();
      final file = await backup.export(passphrase: passphrase);

      expect(await file.exists(), isTrue);
      expect(file.path, endsWith('.yapbackup'));
      expect(await file.length(), greaterThan(0));
    }, timeout: slow);

    test('the note text is not readable in the file', () async {
      await notes.createNote(
        type: NoteType.person,
        title: 'Ritu Sharma',
        body: 'Freelance video editor.',
        tags: const [],
      );
      final file = await backup.export(passphrase: passphrase);
      final raw = String.fromCharCodes(await file.readAsBytes());

      expect(raw, isNot(contains('Ritu Sharma')));
      expect(raw, isNot(contains('Freelance video editor')));
    }, timeout: slow);

    test('refuses a short passphrase before doing any work', () async {
      await seed();
      await expectLater(
        backup.export(passphrase: 'short'),
        throwsA(isA<ValidationException>()
            .having((e) => e.message, 'message', contains('8 characters'))),
      );
    });

    test('leaves no staging files behind', () async {
      await seed();
      await backup.export(passphrase: passphrase);

      final leftovers = work
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.sqlite'))
          .toList();
      expect(leftovers, isEmpty);
    }, timeout: slow);
  });

  group('round trip', () {
    test('restores every note exactly', () async {
      await seed(count: 4);
      final before = await notes.allNotes();
      final file = await backup.export(passphrase: passphrase);

      // Wipe the live database the way a reinstall would.
      for (final note in before) {
        await notes.deleteNote(note.id);
      }
      expect(await notes.allNotes(), isEmpty);

      final prepared =
          await backup.prepareRestore(file: file, passphrase: passphrase);
      expect(prepared.manifest.noteCount, 4);

      await db.close();
      await backup.applyRestore(prepared);

      db = openLive();
      final after = await NoteRepository(db).allNotes();
      expect(after, hasLength(4));
      expect(
        after.map((n) => n.title).toSet(),
        before.map((n) => n.title).toSet(),
      );
      expect(after.map((n) => n.body).toSet(),
          before.map((n) => n.body).toSet());
      expect(after.map((n) => n.tags.join()).toSet(),
          before.map((n) => n.tags.join()).toSet());
    }, timeout: slow);

    test('keeps a safety copy of what it replaced', () async {
      await seed();
      final file = await backup.export(passphrase: passphrase);

      await notes.createNote(
        type: NoteType.idea,
        title: 'Added after the backup',
        body: 'b',
        tags: const [],
      );

      final prepared =
          await backup.prepareRestore(file: file, passphrase: passphrase);
      await db.close();
      final outcome = await backup.applyRestore(prepared);

      expect(await outcome.safetyCopy.exists(), isTrue);

      // The safety copy still has the note the restore rolled back.
      final rescued = AppDatabase(NativeDatabase(outcome.safetyCopy));
      final rescuedNotes = await NoteRepository(rescued).allNotes();
      await rescued.close();

      expect(
        rescuedNotes.map((n) => n.title),
        contains('Added after the backup'),
      );

      db = openLive();
    }, timeout: slow);

    test('full-text search works on restored notes', () async {
      await notes.createNote(
        type: NoteType.person,
        title: 'Ritu Sharma',
        body: 'Freelance video editor.',
        tags: const ['video'],
      );
      final file = await backup.export(passphrase: passphrase);

      final prepared =
          await backup.prepareRestore(file: file, passphrase: passphrase);
      await db.close();
      await backup.applyRestore(prepared);

      db = openLive();
      final hits = await NoteRepository(db).searchFts('editor');
      expect(hits, hasLength(1),
          reason: 'the FTS index must survive the round trip');
    }, timeout: slow);

    test('version history survives', () async {
      final note = await notes.createNote(
        type: NoteType.idea,
        title: 'Original',
        body: 'first body',
        tags: const [],
      );
      await notes.updateNote(
        id: note.id,
        changeSource: ChangeSource.manualEdit,
        body: 'second body',
      );

      final file = await backup.export(passphrase: passphrase);
      final prepared =
          await backup.prepareRestore(file: file, passphrase: passphrase);
      await db.close();
      await backup.applyRestore(prepared);

      db = openLive();
      final versions = await NoteRepository(db).versionsFor(note.id);
      expect(versions.single.body, 'first body');
    }, timeout: slow);
  });

  group('embeddings', () {
    Future<int> embeddingCount(AppDatabase database) async {
      final rows = await database
          .customSelect('SELECT COUNT(*) AS c FROM embeddings')
          .get();
      return rows.single.read<int>('c');
    }

    Future<void> addEmbedding(String noteId) => db.customStatement(
          'INSERT INTO embeddings (note_id, model_id, dims, vector) '
          "VALUES ('$noteId', 'test-model', 4, X'00010203')",
        );

    test('are excluded by default and the manifest says so', () async {
      final note = await notes.createNote(
        type: NoteType.idea, title: 't', body: 'b', tags: const []);
      await addEmbedding(note.id);
      expect(await embeddingCount(db), 1);

      final file = await backup.export(passphrase: passphrase);
      final prepared =
          await backup.prepareRestore(file: file, passphrase: passphrase);

      expect(prepared.manifest.embeddingsIncluded, isFalse);

      await db.close();
      await backup.applyRestore(prepared);
      db = openLive();

      expect(await embeddingCount(db), 0,
          reason: 'derived data is rebuilt, not carried');
      expect(await NoteRepository(db).allNotes(), hasLength(1));
    }, timeout: slow);

    test('can be included when asked', () async {
      final note = await notes.createNote(
        type: NoteType.idea, title: 't', body: 'b', tags: const []);
      await addEmbedding(note.id);

      final file = await backup.export(
        passphrase: passphrase,
        includeEmbeddings: true,
      );
      final prepared =
          await backup.prepareRestore(file: file, passphrase: passphrase);

      expect(prepared.manifest.embeddingsIncluded, isTrue);

      await db.close();
      await backup.applyRestore(prepared);
      db = openLive();

      expect(await embeddingCount(db), 1);
    }, timeout: slow);

    test('excluding them makes the file smaller', () async {
      for (var i = 0; i < 8; i++) {
        final note = await notes.createNote(
            type: NoteType.idea, title: 't$i', body: 'b', tags: const []);
        await db.customStatement(
          'INSERT INTO embeddings (note_id, model_id, dims, vector) '
          "VALUES ('${note.id}', 'm', 512, zeroblob(2048))",
        );
      }

      // Measure before the next export, which clears older ones out.
      final leanSize = await (await backup.export(passphrase: passphrase))
          .length();
      final fullSize = await (await backup.export(
        passphrase: passphrase,
        includeEmbeddings: true,
      ))
          .length();

      expect(leanSize, lessThan(fullSize));
    }, timeout: slow);

    test('a new export clears the previous one out of the cache', () async {
      await seed();
      final first = await backup.export(passphrase: passphrase);
      expect(await first.exists(), isTrue);

      final second = await backup.export(passphrase: passphrase);

      expect(await first.exists(), isFalse,
          reason: 'old exports must not pile up in the cache directory');
      expect(await second.exists(), isTrue);
    }, timeout: slow);
  });

  group('restore refuses', () {
    test('a wrong passphrase, without touching live data', () async {
      await seed();
      final file = await backup.export(passphrase: passphrase);

      await expectLater(
        backup.prepareRestore(file: file, passphrase: 'not the passphrase'),
        throwsA(isA<ValidationException>()),
      );
      expect(await notes.allNotes(), hasLength(3),
          reason: 'the live database must be untouched');
    }, timeout: slow);

    test('a file that is not a backup', () async {
      final junk = File('${work.path}/notes.txt')
        ..writeAsStringSync('this is just a text file');

      await expectLater(
        backup.prepareRestore(file: junk, passphrase: passphrase),
        throwsA(isA<ValidationException>()
            .having((e) => e.message, 'message', contains('not a Yap backup'))),
      );
    });

    test('a real SQLite file that is not a Yap database', () async {
      // The dangerous case: a perfectly valid database from something else.
      // Verification must not open it through drift, because that would run
      // the migration, create the Yap tables and declare it fine — restoring
      // it would then wipe every note.
      final foreign = File('${liveDir.path}/foreign.sqlite');
      final other = sqlite3.open(foreign.path)
        ..execute('CREATE TABLE unrelated (x INTEGER)')
        ..execute('INSERT INTO unrelated VALUES (1)');
      other.close();

      final smuggled = File('${work.path}/smuggled.yapbackup');
      await _sealAsBackup(foreign, smuggled, passphrase);

      await expectLater(
        backup.prepareRestore(file: smuggled, passphrase: passphrase),
        throwsA(isA<ValidationException>()
            .having((e) => e.message, 'message', contains('not a Yap'))),
      );
      expect(await notes.allNotes(), isEmpty,
          reason: 'live data must be untouched');
    }, timeout: slow);

    test('a backup missing one of the Yap tables', () async {
      final crippled = File('${liveDir.path}/crippled.sqlite');
      await seed();
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
      await liveFile.copy(crippled.path);

      final raw = sqlite3.open(crippled.path)
        ..execute('DROP TABLE note_versions');
      raw.close();

      final smuggled = File('${work.path}/crippled.yapbackup');
      await _sealAsBackup(crippled, smuggled, passphrase);

      await expectLater(
        backup.prepareRestore(file: smuggled, passphrase: passphrase),
        throwsA(isA<ValidationException>()
            .having((e) => e.message, 'message', contains('note_versions'))),
      );
    }, timeout: slow);

    test('a corrupted payload', () async {
      await seed();
      final file = await backup.export(passphrase: passphrase);
      final bytes = await file.readAsBytes();
      bytes[bytes.length - 30] ^= 0xFF;
      await file.writeAsBytes(bytes);

      await expectLater(
        backup.prepareRestore(file: file, passphrase: passphrase),
        throwsA(isA<ValidationException>()),
      );
    }, timeout: slow);
  });
}


/// Wraps an arbitrary database file in a well-formed, correctly encrypted
/// backup, so the restore path is tested on its own merits rather than on the
/// envelope rejecting the file first.
Future<void> _sealAsBackup(File db, File out, String passphrase) async {
  final archive = Archive()
    ..addFile(ArchiveFile.string(
      BackupManifest.manifestEntryName,
      jsonEncode(BackupManifest(
        schemaVersion: 2,
        createdAt: DateTime.now(),
        noteCount: 0,
        captureCount: 0,
        embeddingsIncluded: false,
      ).toJson()),
    ))
    ..addFile(ArchiveFile.bytes(
      BackupManifest.dbEntryName,
      await db.readAsBytes(),
    ));

  final sealed = await encryptBackup(EncryptRequest(
    passphrase: passphrase,
    plaintext: Uint8List.fromList(ZipEncoder().encodeBytes(archive)),
  ));
  await out.writeAsBytes(sealed, flush: true);
}
