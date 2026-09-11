import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yapapp/core/errors.dart';
import 'package:yapapp/services/settings/settings_model.dart';
import 'package:yapapp/services/transcription/sarvam_batch_client.dart';
import 'package:yapapp/services/transcription/sarvam_common.dart';
import 'package:yapapp/services/transcription/sarvam_transcription_service.dart';

import 'fake_adapter.dart';

void main() {
  late Directory tempDir;
  late File audio;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('yap_sarvam_test');
    audio = File('${tempDir.path}/9f8b-7c6d.m4a');
    await audio.writeAsBytes(List.filled(64, 7));
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  /// Builds a service wired to fake adapters, returning both so tests can
  /// inspect exactly what went over each connection.
  ({
    SarvamTranscriptionService service,
    FakeAdapter api,
    FakeAdapter storage,
  }) buildService({
    required ResponseBody Function(RecordedRequest) apiHandler,
    ResponseBody Function(RecordedRequest)? storageHandler,
    SarvamModel model = SarvamModel.v4,
    SarvamMode mode = SarvamMode.codemix,
  }) {
    final http = SarvamHttp.forKey('test-key');
    final apiAdapter = FakeAdapter(apiHandler);
    final storageAdapter =
        FakeAdapter(storageHandler ?? (_) => emptyResponse());
    http.api.httpClientAdapter = apiAdapter;
    http.storage.httpClientAdapter = storageAdapter;

    return (
      service: SarvamTranscriptionService(
        http: http,
        model: model,
        mode: mode,
        batchClient: SarvamBatchClient(
          http: http,
          pollInterval: Duration.zero,
          maxWait: const Duration(seconds: 5),
        ),
      ),
      api: apiAdapter,
      storage: storageAdapter,
    );
  }

  group('sanitizeKeyterms', () {
    test('drops blanks and de-duplicates case-insensitively', () {
      expect(sanitizeKeyterms(['Ritu', '  ', 'ritu', 'Aakash']),
          ['Ritu', 'Aakash']);
    });

    test('clamps to 50 terms', () {
      final many = List.generate(80, (i) => 'name$i');
      expect(sanitizeKeyterms(many), hasLength(50));
    });

    test('truncates a term to 64 characters', () {
      final long = 'x' * 100;
      expect(sanitizeKeyterms([long]).single.length, 64);
    });
  });

  group('REST', () {
    test('posts multipart to /speech-to-text with the documented fields',
        () async {
      final built = buildService(
        apiHandler: (_) => jsonResponse({
          'request_id': 'req-1',
          'transcript': 'mera ek idea hai',
          'language_code': 'hi-IN',
        }),
      );

      final transcript = await built.service.transcribe(
        audio,
        keyterms: ['Ritu Sharma'],
        duration: const Duration(seconds: 12),
      );

      expect(transcript.text, 'mera ek idea hai');
      expect(transcript.languageCode, 'hi-IN');
      expect(transcript.requestId, 'req-1');

      final req = built.api.requests.single;
      expect(req.method, 'POST');
      expect(req.uri.toString(), 'https://api.sarvam.ai/speech-to-text');
      expect(req.headers[sarvamAuthHeader], 'test-key');
      expect(req.formField('model'), 'saaras:v4');
      expect(req.formField('mode'), 'codemix');
      expect(req.formField('language_code'), 'unknown');
      expect(req.body, contains('filename="9f8b-7c6d.m4a"'));
    });

    test('sends keyterms as one JSON-encoded array field', () async {
      final built = buildService(
        apiHandler: (_) => jsonResponse({'transcript': 'ok'}),
      );

      await built.service.transcribe(
        audio,
        keyterms: ['Ritu Sharma', 'New Delhi'],
        duration: const Duration(seconds: 5),
      );

      final raw = built.api.requests.single.formField('keyterms');
      expect(raw, isNotNull);
      expect(jsonDecode(raw!), ['Ritu Sharma', 'New Delhi']);
    });

    test('omits keyterms entirely when there are none', () async {
      final built = buildService(
        apiHandler: (_) => jsonResponse({'transcript': 'ok'}),
      );
      await built.service
          .transcribe(audio, duration: const Duration(seconds: 5));

      expect(built.api.requests.single.formField('keyterms'), isNull);
    });

    test('drops keyterms on saaras:v3, which does not support them', () async {
      final built = buildService(
        apiHandler: (_) => jsonResponse({'transcript': 'ok'}),
        model: SarvamModel.v3,
      );

      await built.service.transcribe(
        audio,
        keyterms: ['Ritu Sharma'],
        duration: const Duration(seconds: 5),
      );

      final req = built.api.requests.single;
      expect(req.formField('model'), 'saaras:v3');
      expect(req.formField('keyterms'), isNull);
    });

    test('uses REST right up to the 25 s cutoff', () async {
      final built = buildService(
        apiHandler: (_) => jsonResponse({'transcript': 'ok'}),
      );
      await built.service
          .transcribe(audio, duration: SarvamTranscriptionService.restLimit);

      expect(built.api.requests.single.path, '/speech-to-text');
    });

    test('maps a 401 to an auth error naming Settings', () async {
      final built = buildService(
        apiHandler: (_) => jsonResponse({'error': 'nope'}, status: 401),
      );

      await expectLater(
        built.service.transcribe(audio, duration: const Duration(seconds: 5)),
        throwsA(isA<AuthException>()
            .having((e) => e.message, 'message', contains('Settings'))),
      );
    });

    test('maps a 422 to an api error carrying Sarvam\'s reason', () async {
      final built = buildService(
        apiHandler: (_) => jsonResponse(
          {'error': {'message': 'audio exceeds 30 seconds'}},
          status: 422,
        ),
      );

      await expectLater(
        built.service.transcribe(audio, duration: const Duration(seconds: 5)),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 422)
            .having((e) => e.message, 'message', contains('exceeds 30 seconds'))),
      );
    });

    test('maps a 500 to a retryable network error', () async {
      final built = buildService(
        apiHandler: (_) => jsonResponse({}, status: 503),
      );

      await expectLater(
        built.service.transcribe(audio, duration: const Duration(seconds: 5)),
        throwsA(isA<NetworkException>()),
      );
    });

    test('fails clearly when the recording is gone', () async {
      final built = buildService(apiHandler: (_) => jsonResponse({}));
      await audio.delete();

      await expectLater(
        built.service.transcribe(audio, duration: const Duration(seconds: 5)),
        throwsA(isA<ApiException>()
            .having((e) => e.message, 'message', contains('missing'))),
      );
    });
  });

  group('Batch', () {
    /// Routes the five Sarvam batch endpoints in sequence.
    ResponseBody Function(RecordedRequest) batchRouter({
      String storageType = 'Azure_V1',
      List<String> states = const ['Running', 'Completed'],
      String fileState = 'Success',
    }) {
      var poll = 0;
      return (req) {
        if (req.path == '/speech-to-text/job/v1' && req.method == 'POST') {
          return jsonResponse({
            'job_id': 'job-123',
            'storage_container_type': storageType,
            'job_state': 'Accepted',
          }, status: 202);
        }
        if (req.path == '/speech-to-text/job/v1/upload-files') {
          return jsonResponse({
            'upload_urls': {
              '9f8b-7c6d.m4a': {
                'file_url': 'https://blob.example.com/in/9f8b-7c6d.m4a?sas=1',
              },
            },
          });
        }
        if (req.path == '/speech-to-text/job/v1/job-123/start') {
          return jsonResponse({'job_state': 'Running'});
        }
        if (req.path == '/speech-to-text/job/v1/job-123/status') {
          final state = states[poll < states.length ? poll : states.length - 1];
          poll++;
          return jsonResponse({
            'job_id': 'job-123',
            'job_state': state,
            'job_details': [
              {
                'inputs': [{'file_name': '9f8b-7c6d.m4a', 'file_id': 'in-0'}],
                'outputs': [{'file_name': '0.json', 'file_id': 'out-0'}],
                'state': fileState,
                'error_message': fileState == 'Success' ? null : 'bad audio',
              },
            ],
          });
        }
        if (req.path == '/speech-to-text/job/v1/download-files') {
          return jsonResponse({
            'download_urls': {
              '0.json': {'file_url': 'https://blob.example.com/out/0.json?sas=2'},
            },
          });
        }
        return jsonResponse({'unexpected': req.path}, status: 404);
      };
    }

    ResponseBody storageRouter(RecordedRequest req) {
      if (req.method == 'GET') {
        return jsonResponse({
          'request_id': 'req-9',
          'transcript': 'ek lamba ramble tha',
          'language_code': 'hi-IN',
        });
      }
      return emptyResponse(status: 201);
    }

    test('runs the full six-step flow for long audio', () async {
      final built = buildService(
        apiHandler: batchRouter(),
        storageHandler: storageRouter,
      );

      final transcript = await built.service.transcribe(
        audio,
        keyterms: ['Ritu Sharma'],
        duration: const Duration(minutes: 3),
      );

      expect(transcript.text, 'ek lamba ramble tha');
      expect(transcript.languageCode, 'hi-IN');

      final paths = built.api.requests.map((r) => '${r.method} ${r.path}').toList();
      expect(paths, [
        'POST /speech-to-text/job/v1',
        'POST /speech-to-text/job/v1/upload-files',
        'POST /speech-to-text/job/v1/job-123/start',
        'GET /speech-to-text/job/v1/job-123/status',
        'GET /speech-to-text/job/v1/job-123/status',
        'POST /speech-to-text/job/v1/download-files',
      ]);
    });

    test('puts job parameters, including keyterms, in the init body', () async {
      final built = buildService(
        apiHandler: batchRouter(),
        storageHandler: storageRouter,
      );
      await built.service.transcribe(
        audio,
        keyterms: ['Ritu Sharma'],
        duration: const Duration(minutes: 3),
      );

      final params = built.api.requests.first.json['job_parameters'] as Map;
      expect(params['model'], 'saaras:v4');
      expect(params['mode'], 'codemix');
      expect(params['language_code'], 'unknown');
      expect(params['keyterms'], ['Ritu Sharma']);
    });

    test('uploads to the presigned URL with the Azure block-blob header',
        () async {
      final built = buildService(
        apiHandler: batchRouter(),
        storageHandler: storageRouter,
      );
      await built.service
          .transcribe(audio, duration: const Duration(minutes: 3));

      final put = built.storage.requests.firstWhere((r) => r.method == 'PUT');
      expect(put.uri.toString(),
          'https://blob.example.com/in/9f8b-7c6d.m4a?sas=1');
      expect(put.headers['x-ms-blob-type'], 'BlockBlob');
    });

    test('omits the Azure header for non-Azure storage', () async {
      final built = buildService(
        apiHandler: batchRouter(storageType: 'Google'),
        storageHandler: storageRouter,
      );
      await built.service
          .transcribe(audio, duration: const Duration(minutes: 3));

      final put = built.storage.requests.firstWhere((r) => r.method == 'PUT');
      expect(put.headers.containsKey('x-ms-blob-type'), isFalse);
    });

    test('never sends the Sarvam key to the storage host', () async {
      final built = buildService(
        apiHandler: batchRouter(),
        storageHandler: storageRouter,
      );
      await built.service
          .transcribe(audio, duration: const Duration(minutes: 3));

      expect(built.storage.requests, isNotEmpty);
      for (final req in built.storage.requests) {
        expect(req.headers.containsKey(sarvamAuthHeader), isFalse,
            reason: 'the API key must not leak to a third-party blob store');
      }
    });

    test('polls until the job completes', () async {
      final built = buildService(
        apiHandler: batchRouter(
            states: ['Accepted', 'Pending', 'Running', 'Completed']),
        storageHandler: storageRouter,
      );
      await built.service
          .transcribe(audio, duration: const Duration(minutes: 3));

      final polls = built.api.requests
          .where((r) => r.path.endsWith('/status'))
          .length;
      expect(polls, 4);
    });

    test('surfaces a failed job with Sarvam\'s message', () async {
      final built = buildService(
        apiHandler: (req) {
          if (req.path.endsWith('/status')) {
            return jsonResponse({
              'job_state': 'Failed',
              'error_message': 'unsupported codec',
            });
          }
          return batchRouter()(req);
        },
        storageHandler: storageRouter,
      );

      await expectLater(
        built.service.transcribe(audio, duration: const Duration(minutes: 3)),
        throwsA(isA<ApiException>()
            .having((e) => e.message, 'message', contains('unsupported codec'))),
      );
    });

    test('surfaces a per-file failure inside a completed job', () async {
      final built = buildService(
        apiHandler: batchRouter(states: ['Completed'], fileState: 'API Error'),
        storageHandler: storageRouter,
      );

      await expectLater(
        built.service.transcribe(audio, duration: const Duration(minutes: 3)),
        throwsA(isA<ApiException>()
            .having((e) => e.message, 'message', contains('bad audio'))),
      );
    });

    test('a poll timeout is retryable, not a hard failure', () async {
      final built = buildService(
        apiHandler: batchRouter(states: ['Running']),
        storageHandler: storageRouter,
      );
      final service = SarvamTranscriptionService(
        http: SarvamHttp(
          api: built.service.http.api,
          storage: built.service.http.storage,
        ),
        model: SarvamModel.v4,
        mode: SarvamMode.codemix,
        batchClient: SarvamBatchClient(
          http: built.service.http,
          pollInterval: Duration.zero,
          maxWait: Duration.zero,
        ),
      );

      await expectLater(
        service.transcribe(audio, duration: const Duration(minutes: 3)),
        throwsA(isA<NetworkException>()
            .having((e) => e.message, 'message', contains('Retry'))),
      );
    });

    test('an unknown duration takes the safe Batch path', () async {
      final built = buildService(
        apiHandler: batchRouter(),
        storageHandler: storageRouter,
      );
      await built.service.transcribe(audio);

      expect(built.api.requests.first.path, '/speech-to-text/job/v1');
    });

    test('audio just over the cutoff uses Batch, not REST', () async {
      final built = buildService(
        apiHandler: batchRouter(),
        storageHandler: storageRouter,
      );
      await built.service
          .transcribe(audio, duration: const Duration(seconds: 26));

      expect(built.api.requests.first.path, '/speech-to-text/job/v1');
    });
  });
}
