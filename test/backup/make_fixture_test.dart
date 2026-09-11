@Tags(['fixture'])
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yapapp/data/db/database.dart';
import 'package:yapapp/data/models/enums.dart';
import 'package:yapapp/data/repositories/note_repository.dart';
import 'package:yapapp/services/backup/backup_service.dart';

/// Builds a real .yapbackup with seeded notes for on-device restore testing.
void main() {
  test('write fixture', () async {
    final dir = await Directory.systemTemp.createTemp('yap_fixture');
    final dbFile = File('${dir.path}/yap.sqlite');
    final db = AppDatabase(NativeDatabase(dbFile));
    final notes = NoteRepository(db);

    await notes.createNote(
      type: NoteType.person,
      title: 'Ritu Sharma',
      body: 'Freelance video editor, met at the Goa wedding shoot. '
          'Does colour grading too.',
      tags: ['video', 'editing'],
    );
    await notes.createNote(
      type: NoteType.idea,
      title: 'Time-loop delivery movie',
      body: 'A courier in Mumbai reliving one monsoon delivery run.',
      tags: ['movie'],
    );
    await notes.createNote(
      type: NoteType.rule,
      title: 'Never eat prawns',
      body: 'Bad reaction in Goa, twice.',
      tags: ['food'],
    );

    final service = BackupService(
      database: db,
      databasePath: () async => dbFile.path,
      workDirectory: () async => dir,
    );
    final out = await service.export(passphrase: 'testpassphrase');
    await out.copy('/tmp/yap-fixture.yapbackup');
    await db.close();

    // ignore: avoid_print
    print('FIXTURE_BYTES=${await out.length()}');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
