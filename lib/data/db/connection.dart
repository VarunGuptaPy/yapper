import 'package:drift_flutter/drift_flutter.dart';

import 'database.dart';

/// Opens the on-device database at `<app support>/yap.sqlite`.
///
/// `drift_flutter` runs the database on a background isolate, so queries never
/// block the UI thread.
AppDatabase openAppDatabase() => AppDatabase(
      driftDatabase(
        name: 'yap',
        native: const DriftNativeOptions(shareAcrossIsolates: true),
      ),
    );
