import 'package:record/record.dart';

import '../../core/errors.dart';
import '../../core/ids.dart';
import 'audio_paths.dart';

/// A finished recording, ready to become a `captures` row.
class RecordedAudio {
  const RecordedAudio({
    required this.captureId,
    required this.path,
    required this.duration,
  });

  final String captureId;
  final String path;
  final Duration duration;
}

/// Wraps `record` with the encoding Yap needs: AAC-LC, 16 kHz, mono — the
/// sample rate Sarvam works best with, and small enough to upload over mobile
/// data (SPEC.md §4).
class RecorderService {
  RecorderService({AudioRecorder? recorder})
      : _recorder = recorder ?? AudioRecorder();

  static const _config = RecordConfig(
    encoder: AudioEncoder.aacLc,
    sampleRate: 16000,
    numChannels: 1,
  );

  final AudioRecorder _recorder;
  static const _paths = AudioPaths();

  String? _captureId;
  DateTime? _startedAt;

  bool get isRecording => _captureId != null;

  Future<bool> hasPermission() => _recorder.hasPermission();

  /// Amplitude for the level meter, sampled a few times a second.
  Stream<Amplitude> amplitudeStream() =>
      _recorder.onAmplitudeChanged(const Duration(milliseconds: 200));

  /// Starts a new recording and returns the capture id its file is named after.
  Future<String> start() async {
    if (isRecording) {
      throw const RecordingException('Already recording.');
    }
    if (!await _recorder.hasPermission()) {
      throw const RecordingException(
        'Microphone permission denied. Enable it in system settings.',
      );
    }

    final captureId = newId();
    final path = await _paths.pathForCapture(captureId);

    try {
      await _recorder.start(_config, path: path);
    } catch (e) {
      throw RecordingException('Could not start recording.', cause: e);
    }

    _captureId = captureId;
    _startedAt = DateTime.now();
    return captureId;
  }

  /// Stops and returns the file. Duration is measured on our side because the
  /// encoder does not report it, and the pipeline needs it to choose between
  /// Sarvam's REST and Batch endpoints.
  Future<RecordedAudio> stop() async {
    final captureId = _captureId;
    final startedAt = _startedAt;
    if (captureId == null || startedAt == null) {
      throw const RecordingException('Not recording.');
    }

    final duration = DateTime.now().difference(startedAt);
    _captureId = null;
    _startedAt = null;

    final String? path;
    try {
      path = await _recorder.stop();
    } catch (e) {
      throw RecordingException('Could not stop the recording.', cause: e);
    }
    if (path == null) {
      throw const RecordingException('The recording produced no file.');
    }

    return RecordedAudio(
      captureId: captureId,
      path: path,
      duration: duration,
    );
  }

  /// Aborts and deletes the file.
  Future<void> cancel() async {
    _captureId = null;
    _startedAt = null;
    await _recorder.cancel();
  }

  Future<void> dispose() => _recorder.dispose();
}
