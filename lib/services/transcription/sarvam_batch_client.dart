import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../core/errors.dart';
import '../../core/log.dart';
import '../../data/models/transcript.dart';
import 'sarvam_common.dart';

/// Sarvam's asynchronous Batch job, for audio the 30-second REST endpoint
/// cannot take. The six steps are documented in SPEC.md §14.2.
class SarvamBatchClient {
  SarvamBatchClient({
    required this.http,
    this.pollInterval = const Duration(seconds: 5),
    this.maxWait = const Duration(minutes: 15),
  });

  final SarvamHttp http;

  final Duration pollInterval;
  final Duration maxWait;

  Future<Transcript> transcribe(
    File audio, {
    required String model,
    required String mode,
    List<String> keyterms = const [],
  }) async {
    final fileName = p.basename(audio.path);

    final job = await _initJob(model: model, mode: mode, keyterms: keyterms);
    final jobId = job.jobId;
    logD('SarvamBatch', 'job $jobId created');

    final uploadUrl = await _uploadUrlFor(jobId, fileName);
    await _putFile(audio, uploadUrl, job.isAzureStorage);
    await _startJob(jobId);

    final status = await _pollUntilDone(jobId);
    final outputName = _outputFileName(status, jobId);
    final downloadUrl = await _downloadUrlFor(jobId, outputName);
    return _fetchTranscript(downloadUrl);
  }

  Future<_JobHandle> _initJob({
    required String model,
    required String mode,
    required List<String> keyterms,
  }) async {
    final terms = sanitizeKeyterms(keyterms);
    try {
      final res = await http.api.post<Map<String, dynamic>>(
        '/speech-to-text/job/v1',
        data: {
          'job_parameters': {
            'model': model,
            'mode': mode,
            'language_code': 'unknown',
            if (terms.isNotEmpty) 'keyterms': terms,
          },
        },
      );
      final body = res.data ?? const {};
      final jobId = body['job_id'];
      if (jobId is! String || jobId.isEmpty) {
        throw const ApiException('Sarvam did not return a job id.');
      }
      return _JobHandle(
        jobId: jobId,
        storageContainerType: body['storage_container_type'] as String? ?? '',
      );
    } on DioException catch (e) {
      throw mapSarvamError(e, 'Creating the transcription job');
    }
  }

  Future<String> _uploadUrlFor(String jobId, String fileName) async {
    try {
      final res = await http.api.post<Map<String, dynamic>>(
        '/speech-to-text/job/v1/upload-files',
        data: {
          'job_id': jobId,
          'files': [fileName],
        },
      );
      final url = _fileUrl(res.data?['upload_urls'], fileName);
      if (url == null) {
        throw const ApiException('Sarvam did not return an upload URL.');
      }
      return url;
    } on DioException catch (e) {
      throw mapSarvamError(e, 'Requesting an upload URL');
    }
  }

  /// Uploads the audio to the presigned URL.
  ///
  /// Azure block blobs reject a PUT without `x-ms-blob-type`, which is the one
  /// piece of this flow Sarvam's own docs only show through their SDK.
  Future<void> _putFile(File audio, String url, bool isAzure) async {
    final length = await audio.length();
    try {
      await http.storage.put<void>(
        url,
        data: audio.openRead(),
        options: Options(
          headers: {
            Headers.contentLengthHeader: length,
            if (isAzure) 'x-ms-blob-type': 'BlockBlob',
          },
          contentType: 'audio/mp4',
        ),
      );
    } on DioException catch (e) {
      throw mapSarvamError(e, 'Uploading the recording');
    }
  }

  Future<void> _startJob(String jobId) async {
    try {
      await http.api.post<Map<String, dynamic>>('/speech-to-text/job/v1/$jobId/start');
    } on DioException catch (e) {
      throw mapSarvamError(e, 'Starting the transcription job');
    }
  }

  Future<Map<String, dynamic>> _pollUntilDone(String jobId) async {
    final deadline = DateTime.now().add(maxWait);

    while (true) {
      final Map<String, dynamic> status;
      try {
        final res = await http.api.get<Map<String, dynamic>>(
          '/speech-to-text/job/v1/$jobId/status',
        );
        status = res.data ?? const {};
      } on DioException catch (e) {
        throw mapSarvamError(e, 'Checking the transcription job');
      }

      final state = status['job_state'] as String? ?? '';
      logD('SarvamBatch', 'job $jobId is $state');

      if (state == 'Completed') return status;
      if (state == 'Failed') {
        final message = status['error_message'] as String?;
        throw ApiException(
          'Sarvam could not transcribe this recording.'
          '${message == null || message.isEmpty ? '' : ' $message'}',
        );
      }

      if (DateTime.now().isAfter(deadline)) {
        // Retryable on purpose: the job may well still finish, and Retry
        // re-enters this flow rather than losing the recording.
        throw NetworkException(
          'Sarvam is still working after ${maxWait.inMinutes} minutes. '
          'Tap Retry to check again.',
        );
      }

      await Future<void>.delayed(pollInterval);
    }
  }

  /// Finds the output file name for our single uploaded file, and surfaces a
  /// per-file failure that a `Completed` job can still contain.
  String _outputFileName(Map<String, dynamic> status, String jobId) {
    final details = status['job_details'];
    if (details is List) {
      for (final detail in details) {
        if (detail is! Map) continue;
        final state = detail['state'] as String?;
        if (state != null && state != 'Success') {
          final message = detail['error_message'] as String?;
          throw ApiException(
            'Sarvam failed on this recording.'
            '${message == null || message.isEmpty ? '' : ' $message'}',
          );
        }
        final outputs = detail['outputs'];
        if (outputs is List) {
          for (final output in outputs) {
            if (output is Map && output['file_name'] is String) {
              return output['file_name'] as String;
            }
          }
        }
      }
    }
    throw const ApiException('Sarvam reported no transcript file for the job.');
  }

  Future<String> _downloadUrlFor(String jobId, String fileName) async {
    try {
      final res = await http.api.post<Map<String, dynamic>>(
        '/speech-to-text/job/v1/download-files',
        data: {
          'job_id': jobId,
          'files': [fileName],
        },
      );
      final url = _fileUrl(res.data?['download_urls'], fileName);
      if (url == null) {
        throw const ApiException('Sarvam did not return a download URL.');
      }
      return url;
    } on DioException catch (e) {
      throw mapSarvamError(e, 'Requesting the transcript');
    }
  }

  Future<Transcript> _fetchTranscript(String url) async {
    final Response<dynamic> res;
    try {
      // Fetch the raw body rather than letting Dio decide. Blob storage serves
      // the output file as application/octet-stream, and Dio only auto-decodes
      // JSON when the content type says so — otherwise `data` arrives as a
      // String and a naive `is Map` check fails on a perfectly good transcript.
      res = await http.storage.get<dynamic>(
        url,
        options: Options(responseType: ResponseType.plain),
      );
    } on DioException catch (e) {
      throw mapSarvamError(e, 'Downloading the transcript');
    }

    final map = _decodeTranscript(
      res.data,
      res.headers.value(Headers.contentTypeHeader),
    );

    final text = map['transcript'];
    if (text is! String) {
      throw const ApiException('The transcript file had no "transcript" field.');
    }
    return Transcript(
      text: text.trim(),
      languageCode: map['language_code'] as String?,
      requestId: map['request_id'] as String?,
    );
  }

  /// Reads the downloaded transcript regardless of how storage labelled it.
  Map<String, dynamic> _decodeTranscript(Object? data, String? contentType) {
    if (data is Map<String, dynamic>) return data;

    final raw = switch (data) {
      String s => s,
      List<int> bytes => utf8.decode(bytes, allowMalformed: true),
      _ => null,
    };
    if (raw == null) {
      throw const ApiException(
        'The transcript download returned no readable body.',
      );
    }

    // A UTF-8 BOM is legal in the file but not accepted by jsonDecode.
    final cleaned = raw.replaceFirst('\uFEFF', '').trim();
    if (cleaned.isEmpty) {
      throw const ApiException('The transcript file was empty.');
    }

    // Blob stores report a rejected or expired link as an XML error document,
    // which is worth naming rather than calling "not JSON".
    if (cleaned.startsWith('<')) {
      final code = _xmlErrorCode(cleaned);
      throw ApiException(
        'Storage rejected the transcript link'
        '${code == null ? '' : ' ($code)'}. Tap Retry.',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(cleaned);
    } on FormatException {
      throw ApiException(
        'The transcript file could not be read'
        '${contentType == null ? '' : ', served as $contentType'}.',
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw const ApiException('The transcript file was not a JSON object.');
    }
    return decoded;
  }

  String? _xmlErrorCode(String body) =>
      RegExp(r'<Code>([^<]+)</Code>').firstMatch(body)?.group(1);

  /// Both `upload_urls` and `download_urls` are maps of filename -> {file_url}.
  /// The key is matched leniently because Sarvam has been known to return the
  /// name it stored rather than the one we sent.
  String? _fileUrl(Object? urls, String fileName) {
    if (urls is! Map) return null;
    final entry = urls[fileName] ?? (urls.values.isNotEmpty ? urls.values.first : null);
    if (entry is Map && entry['file_url'] is String) {
      return entry['file_url'] as String;
    }
    return null;
  }
}

class _JobHandle {
  const _JobHandle({required this.jobId, required this.storageContainerType});

  final String jobId;
  final String storageContainerType;

  bool get isAzureStorage => storageContainerType.toLowerCase().startsWith('azure');
}
