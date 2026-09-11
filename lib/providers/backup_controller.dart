import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors.dart';
import '../core/log.dart';
import '../services/backup/backup_service.dart';
import 'providers.dart';

enum BackupPhase { idle, exporting, verifying, restoring }

class BackupState {
  const BackupState({this.phase = BackupPhase.idle, this.error});

  final BackupPhase phase;
  final String? error;

  bool get isBusy => phase != BackupPhase.idle;
}

class BackupController extends Notifier<BackupState> {
  @override
  BackupState build() => const BackupState();

  /// Writes an encrypted backup and hands back the file to share.
  Future<File?> export({
    required String passphrase,
    required bool includeEmbeddings,
  }) =>
      _run(BackupPhase.exporting, () async {
        return ref.read(backupServiceProvider).export(
              passphrase: passphrase,
              includeEmbeddings: includeEmbeddings,
            );
      });

  /// Decrypts and validates, without touching anything live.
  Future<PreparedRestore?> prepare({
    required File file,
    required String passphrase,
  }) =>
      _run(BackupPhase.verifying, () async {
        return ref
            .read(backupServiceProvider)
            .prepareRestore(file: file, passphrase: passphrase);
      });

  /// Closes the live database, swaps the verified file in, and reopens.
  ///
  /// The close has to happen here rather than inside the service: the database
  /// is owned by a provider, and SQLite will not let the file be replaced from
  /// under an open connection.
  Future<RestoreOutcome?> apply(PreparedRestore prepared) =>
      _run(BackupPhase.restoring, () async {
        final service = ref.read(backupServiceProvider);
        await ref.read(appDatabaseProvider).close();

        final outcome = await service.applyRestore(prepared);

        // Rebuilds the database and everything watching it.
        ref.invalidate(appDatabaseProvider);
        logD('Backup', 'database reopened after restore');
        return outcome;
      });

  Future<T?> _run<T>(BackupPhase phase, Future<T> Function() action) async {
    if (state.isBusy) return null;
    state = BackupState(phase: phase);
    try {
      final result = await action();
      state = const BackupState();
      return result;
    } on AppException catch (e) {
      state = BackupState(error: e.message);
      return null;
    } catch (e) {
      logE('Backup', 'failed', e);
      state = const BackupState(error: 'Something went wrong. Try again.');
      return null;
    }
  }

  void dismissError() => state = const BackupState();
}

final backupControllerProvider =
    NotifierProvider<BackupController, BackupState>(BackupController.new);
