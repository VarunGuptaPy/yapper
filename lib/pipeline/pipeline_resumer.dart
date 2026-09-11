import 'dart:async';

import '../core/log.dart';
import '../data/repositories/capture_repository.dart';
import '../services/connectivity_service.dart';
import 'capture_pipeline.dart';

/// Restarts work the app could not finish: captures interrupted by a crash or
/// a force-quit, and captures queued while offline (SPEC.md §7.6).
class PipelineResumer {
  PipelineResumer({
    required this.pipeline,
    required this.captures,
    required this.connectivity,
  });

  final CapturePipeline pipeline;
  final CaptureRepository captures;
  final ConnectivityService connectivity;

  StreamSubscription<bool>? _subscription;
  bool _sweeping = false;

  /// Sweeps once for anything already stuck, then keeps watching for the
  /// network to come back.
  Future<void> start() async {
    _subscription ??= connectivity.onStatusChanged.listen((online) {
      if (online) unawaited(_sweep());
    });
    await _sweep();
  }

  /// Processes stuck captures one at a time, oldest first.
  ///
  /// Sequential on purpose: these each make a transcription and an LLM call,
  /// and firing five at once on a mid-range phone on mobile data is how you
  /// get rate-limited and janky at the same time.
  Future<void> _sweep() async {
    if (_sweeping) return;
    _sweeping = true;
    try {
      final stuck = await captures.inProgress();
      if (stuck.isEmpty) return;
      logD('Resumer', 'resuming ${stuck.length} capture(s)');
      for (final capture in stuck) {
        await pipeline.process(capture.id);
      }
    } finally {
      _sweeping = false;
    }
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }
}
