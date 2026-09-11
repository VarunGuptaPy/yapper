import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yapapp/core/errors.dart';
import 'package:yapapp/services/llm/llm_models.dart';
import 'package:yapapp/services/llm/openai_compatible_llm_service.dart';

import 'fake_adapter.dart';

void main() {
  ({OpenAiCompatibleLlmService service, FakeAdapter adapter}) build({
    required ResponseBody Function(RecordedRequest) handler,
    String baseUrl = 'https://api.example.com/v1',
    String model = 'some-model',
    String apiKey = 'sk-test',
  }) {
    final adapter = FakeAdapter(handler);
    final dio = Dio()..httpClientAdapter = adapter;
    return (
      service: OpenAiCompatibleLlmService(
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: model,
        dio: dio,
      ),
      adapter: adapter,
    );
  }

  ResponseBody okWith(String content) => jsonResponse({
        'choices': [
          {'message': {'role': 'assistant', 'content': content}},
        ],
      });

  group('base URL', () {
    test('strips trailing slashes', () {
      expect(
        OpenAiCompatibleLlmService.normalizeBaseUrl('https://x.com/v1///'),
        'https://x.com/v1',
      );
    });

    test('accepts a URL that already names the endpoint', () {
      expect(
        OpenAiCompatibleLlmService.normalizeBaseUrl(
            'https://x.com/v1/chat/completions'),
        'https://x.com/v1',
      );
    });

    test('posts to /chat/completions under the base URL', () async {
      final built = build(handler: (_) => okWith('ok'));
      await built.service.complete(const [ChatMessage.user('hi')]);

      expect(built.adapter.requests.single.uri.toString(),
          'https://api.example.com/v1/chat/completions');
    });
  });

  test('sends the bearer token, model and messages', () async {
    final built = build(handler: (_) => okWith('ok'));
    await built.service.complete(const [
      ChatMessage.system('be brief'),
      ChatMessage.user('hello'),
    ]);

    final req = built.adapter.requests.single;
    expect(req.headers['Authorization'], 'Bearer sk-test');
    expect(req.json['model'], 'some-model');
    final messages = req.json['messages'] as List;
    expect(messages, hasLength(2));
    expect((messages.first as Map)['role'], 'system');
    expect((messages.last as Map)['content'], 'hello');
  });

  test('requests JSON mode only when asked', () async {
    final built = build(handler: (_) => okWith('{}'));

    await built.service.complete(const [ChatMessage.user('x')], jsonMode: true);
    expect(built.adapter.requests.last.json['response_format'],
        {'type': 'json_object'});

    await built.service.complete(const [ChatMessage.user('x')]);
    expect(built.adapter.requests.last.json.containsKey('response_format'),
        isFalse);
  });

  test('omits tools when none are given', () async {
    final built = build(handler: (_) => okWith('ok'));
    await built.service.complete(const [ChatMessage.user('x')]);
    expect(built.adapter.requests.single.json.containsKey('tools'), isFalse);
  });

  test('serialises tool definitions and parses tool calls', () async {
    final built = build(
      handler: (_) => jsonResponse({
        'choices': [
          {
            'message': {
              'role': 'assistant',
              'content': null,
              'tool_calls': [
                {
                  'id': 'call_1',
                  'type': 'function',
                  'function': {
                    'name': 'search_notes',
                    'arguments': '{"query":"video editing"}',
                  },
                },
              ],
            },
          },
        ],
      }),
    );

    final response = await built.service.complete(
      const [ChatMessage.user('who can edit video?')],
      tools: const [
        ToolDefinition(
          name: 'search_notes',
          description: 'Search the notes',
          parameters: {'type': 'object'},
        ),
      ],
    );

    final sent = built.adapter.requests.single.json['tools'] as List;
    expect((sent.single as Map)['function'], containsPair('name', 'search_notes'));

    expect(response.hasToolCalls, isTrue);
    expect(response.toolCalls.single.name, 'search_notes');
    expect(jsonDecode(response.toolCalls.single.argumentsJson),
        {'query': 'video editing'});
  });

  test('returns the assistant content', () async {
    final built = build(handler: (_) => okWith('{"notes":[]}'));
    final response = await built.service.complete(const [ChatMessage.user('x')]);
    expect(response.content, '{"notes":[]}');
    expect(response.hasToolCalls, isFalse);
  });

  group('errors', () {
    test('401 points at Settings', () async {
      final built = build(handler: (_) => jsonResponse({}, status: 401));
      await expectLater(
        built.service.complete(const [ChatMessage.user('x')]),
        throwsA(isA<AuthException>()
            .having((e) => e.message, 'message', contains('Settings'))),
      );
    });

    test('404 hints at the base URL', () async {
      final built = build(handler: (_) => jsonResponse({}, status: 404));
      await expectLater(
        built.service.complete(const [ChatMessage.user('x')]),
        throwsA(isA<ApiException>()
            .having((e) => e.message, 'message', contains('/v1'))),
      );
    });

    test('429 and 5xx are retryable', () async {
      for (final status in [429, 500, 502]) {
        final built = build(handler: (_) => jsonResponse({}, status: status));
        await expectLater(
          built.service.complete(const [ChatMessage.user('x')]),
          throwsA(isA<NetworkException>()),
          reason: 'status $status should be retryable',
        );
      }
    });

    test('a provider error message is surfaced', () async {
      final built = build(
        handler: (_) => jsonResponse(
          {'error': {'message': 'context length exceeded'}},
          status: 400,
        ),
      );
      await expectLater(
        built.service.complete(const [ChatMessage.user('x')]),
        throwsA(isA<ApiException>().having(
            (e) => e.message, 'message', contains('context length exceeded'))),
      );
    });

    test('a response with no choices is rejected', () async {
      final built = build(handler: (_) => jsonResponse({'choices': []}));
      await expectLater(
        built.service.complete(const [ChatMessage.user('x')]),
        throwsA(isA<ApiException>()),
      );
    });

    test('an empty model name fails before any request', () async {
      final built = build(handler: (_) => okWith('ok'), model: '  ');
      await expectLater(
        built.service.complete(const [ChatMessage.user('x')]),
        throwsA(isA<AuthException>()),
      );
      expect(built.adapter.requests, isEmpty);
    });
  });
}
