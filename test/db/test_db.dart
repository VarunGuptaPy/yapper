import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:yapapp/data/db/database.dart';

/// A fresh in-memory database per test. FTS5 is compiled into the bundled
/// SQLite that `sqlite3` ships, so the triggers behave exactly as on device.
AppDatabase openTestDatabase() =>
    AppDatabase(DatabaseConnection(NativeDatabase.memory()));
