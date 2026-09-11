import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../core/errors.dart';
import '../../core/log.dart';
import '../../data/models/transcript.dart';
import '../settings/settings_model.dart';
import 'sarvam_batch_client.dart';
import 'sarvam_common.dart';
import 'transcription_service.dart';

/// Sarvam Saaras speech-to-text.
///
/// Picks the synchronous REST endpoint for short recordings and the
/// asynchronous Batch job for anything longer, because REST hard-fails with a
/// 422 above 30 s (SPEC.md §14.2).
class SarvamTranscriptionService implements TranscriptionService {
  SarvamTranscriptionService({
    required this.http,
    required this.model,
    required this.mode,
    SarvamBatchClient? batchClient,
  }) : batchClient = batchClient ?? SarvamBatchClient(http: http);

  /// Sarvam's limit is 30 s. The margin absorbs the difference between the
  /// timer we showed the user and what the encoder actually wrote to the file.
  static const restLimit = Duration(seconds: 25);

  final SarvamHttp http;
  final SarvamModel model;
  final SarvamMode mode;
  final SarvamBatchClient batchClient;

  @override
  Future<Transcript> transcribe(
    File audio, {
    List<String> keyterms = const [],
    Duration? duration,
  }) async {
    if (!await audio.exists()) {
      throw ApiException('The recording is missing from storage.');
    }

    // With an unknown duration we cannot risk the 30 s REST ceiling, so the
    // slower path is the safe default.
    final useRest = duration != null && duration <= restLimit;
    logD('Sarvam', 'transcribing via ${useRest ? 'REST' : 'Batch'}');

    if (useRest) {
      return _transcribeRest(audio, keyterms);
    }
    return batchClient.transcribe(
      audio,
      model: model.wire,
      mode: mode.wire,
      keyterms: _keytermsFor(keyterms),
    );
  }

  Future<Transcript> _transcribeRest(File audio, List<String> keyterms) async {
    final terms = _keytermsFor(keyterms);

    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(
        audio.path,
        filename: p.basename(audio.path),
      ),
      'model': model.wire,
      'mode': mode.wire,
      'language_code': 'unknown',
      // Sarvam expects one form field holding a JSON array, not repeated fields.
      if (terms.isNotEmpty) 'keyterms': jsonEncode(terms),
    });

    try {
      final res = await http.api.post<Map<String, dynamic>>(
        '/speech-to-text',
        data: form,
      );
      final body = res.data ?? const {};
      final text = body['transcript'];
      if (text is! String) {
        throw const ApiException('Sarvam returned no transcript.');
      }
      return Transcript(
        text: text.trim(),
        languageCode: body['language_code'] as String?,
        requestId: body['request_id'] as String?,
      );
    } on DioException catch (e) {
      throw mapSarvamError(e, 'Transcribing the recording');
    }
  }

  /// Keyterms are documented as `saaras:v4` only; sending them to v3 would be
  /// rejected, so they are dropped rather than failing the whole transcription.
  List<String> _keytermsFor(List<String> keyterms) =>
      model.supportsKeyterms ? sanitizeKeyterms(keyterms) : const [];
}
