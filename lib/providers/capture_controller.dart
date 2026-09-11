import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:record/record.dart';

import '../core/errors.dart';
import '../core/log.dart';
import 'providers.dart';

class RecordingState {
  const RecordingState({
    this.isRecording = false,
    this.elapsed = Duration.zero,
    this.level = 0,
    this.error,
  });

  final bool isRecording;
  final Duration elapsed;

  /// Mic level, 0 to 1, for the button's pulse.
  final double level;

  final String? error;

  RecordingState copyWith({
    bool? isRecording,
    Duration? elapsed,
    double? level,
    String? error,
    bool clearError = false,
  }) =>
      RecordingState(
        isRecording: isRecording ?? this.isRecording,
        elapsed: elapsed ?? this.elapsed,
        level: level ?? this.level,
        error: clearError ? null : (error ?? this.error),
      );
}

/// Owns the mic button's state: start, tick, stop, hand off to the pipeline.
class CaptureController extends Notifier<RecordingState> {
  Timer? _ticker;
  StreamSubscription<Amplitude>? _levels;
  DateTime? _startedAt;

  @override
  RecordingState build() {
    ref.onDispose(_teardown);
    return const RecordingState();
  }

  Future<void> toggle() => state.isRecording ? stop() : start();

  Future<void> start() async {
    if (state.isRecording) return;
    final recorder = ref.read(recorderServiceProvider);

    try {
      await recorder.start();
    } on AppException catch (e) {
      state = state.copyWith(error: e.message);
      return;
    }

    _startedAt = DateTime.now();
    state = const RecordingState(isRecording: true);

    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final started = _startedAt;
      if (started == null) return;
      state = state.copyWith(elapsed: DateTime.now().difference(started));
    });

    _levels = recorder.amplitudeStream().listen((amplitude) {
      state = state.copyWith(level: _normalize(amplitude.current));
    });
  }

  /// Stops, writes the `captures` row, and kicks off processing in the
  /// background so the UI returns immediately.
  Future<void> stop() async {
    if (!state.isRecording) return;
    _stopTicking();

    try {
      final recorded = await ref.read(recorderServiceProvider).stop();
      state = const RecordingState();

      await ref.read(captureRepositoryProvider).createCapture(
            id: recorded.captureId,
            audioPath: recorded.path,
            durationMs: recorded.duration.inMilliseconds,
          );

      unawaited(ref.read(capturePipelineProvider).process(recorded.captureId));
    } on AppException catch (e) {
      state = RecordingState(error: e.message);
      logE('Capture', 'stop failed: ${e.message}');
    }
  }

  Future<void> cancel() async {
    _stopTicking();
    await ref.read(recorderServiceProvider).cancel();
    state = const RecordingState();
  }

  Future<void> retry(String captureId) =>
      ref.read(capturePipelineProvider).retry(captureId);

  void dismissError() => state = state.copyWith(clearError: true);

  void _stopTicking() {
    _ticker?.cancel();
    _ticker = null;
    _levels?.cancel();
    _levels = null;
    _startedAt = null;
  }

  void _teardown() => _stopTicking();

  /// `record` reports dBFS: 0 is clipping, -45 or below is effectively silence.
  double _normalize(double dbfs) {
    const floor = -45.0;
    if (dbfs <= floor) return 0;
    if (dbfs >= 0) return 1;
    return (dbfs - floor) / -floor;
  }
}

final captureControllerProvider =
    NotifierProvider<CaptureController, RecordingState>(CaptureController.new);
