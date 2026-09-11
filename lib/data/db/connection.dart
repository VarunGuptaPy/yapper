import 'package:drift_flutter/drift_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'database.dart';

const _databaseName = 'yap';

/// The one place that knows where the database file lives.
///
/// Backup and restore have to find, copy and replace this exact file, so the
/// path is defined here and handed to drift rather than relying on its default
/// — two independent guesses at the same location is how a restore ends up
/// writing next to the live database instead of over it.
Future<String> appDatabasePath() async {
  final directory = await getApplicationDocumentsDirectory();
  return p.join(directory.path, '$_databaseName.sqlite');
}

/// Opens the on-device database.
///
/// `drift_flutter` runs it on a background isolate, so queries never block the
/// UI thread.
AppDatabase openAppDatabase() => AppDatabase(
      driftDatabase(
        name: _databaseName,
        native: DriftNativeOptions(
          databasePath: appDatabasePath,
          shareAcrossIsolates: true,
        ),
      ),
    );
