import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/errors.dart';
import 'llm_models.dart';
import 'llm_service.dart';

/// Talks to any provider that speaks the OpenAI `/chat/completions` shape.
///
/// Base URL, key and model all come from Settings, so pointing Yap at a
/// different provider never needs a code change (SPEC.md §5).
class OpenAiCompatibleLlmService implements LlmService {
  OpenAiCompatibleLlmService({
    required String baseUrl,
    required String apiKey,
    required this.model,
    Dio? dio,
  })  : _baseUrl = normalizeBaseUrl(baseUrl),
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(minutes: 3),
              sendTimeout: const Duration(seconds: 60),
            )) {
    if (apiKey.isNotEmpty) {
      _dio.options.headers['Authorization'] = 'Bearer $apiKey';
    }
  }

  final String _baseUrl;
  final String model;
  final Dio _dio;

  /// Trims trailing slashes and a trailing `/chat/completions`, so both
  /// `https://host/v1` and `https://host/v1/chat/completions` work.
  static String normalizeBaseUrl(String raw) {
    var url = raw.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    const suffix = '/chat/completions';
    if (url.endsWith(suffix)) {
      url = url.substring(0, url.length - suffix.length);
    }
    return url;
  }

  @override
  Future<LlmResponse> complete(
    List<ChatMessage> messages, {
    bool jsonMode = false,
    List<ToolDefinition> tools = const [],
    double temperature = 0.2,
  }) async {
    if (model.trim().isEmpty) {
      throw const AuthException('No LLM model set. Add one in Settings.');
    }

    final body = <String, dynamic>{
      'model': model,
      'messages': [for (final m in messages) m.toJson()],
      'temperature': temperature,
      if (jsonMode) 'response_format': {'type': 'json_object'},
      if (tools.isNotEmpty) 'tools': [for (final t in tools) t.toJson()],
    };

    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '$_baseUrl/chat/completions',
        data: body,
      );
      return _parse(res.data);
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  /// A cheap round trip for the Settings "Test connection" button.
  Future<void> testConnection() async {
    await complete(
      const [ChatMessage.user('Reply with the single word: ok')],
      temperature: 0,
    );
  }

  LlmResponse _parse(Map<String, dynamic>? data) {
    final choices = data?['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const ApiException('The LLM returned no choices.');
    }
    final message = (choices.first as Map)['message'];
    if (message is! Map) {
      throw const ApiException('The LLM returned a malformed message.');
    }

    final rawToolCalls = message['tool_calls'];
    final toolCalls = <ToolCall>[];
    if (rawToolCalls is List) {
      for (final call in rawToolCalls) {
        if (call is! Map) continue;
        final fn = call['function'];
        if (fn is! Map) continue;
        toolCalls.add(ToolCall(
          id: call['id'] as String? ?? '',
          name: fn['name'] as String? ?? '',
          argumentsJson: fn['arguments'] is String
              ? fn['arguments'] as String
              : jsonEncode(fn['arguments'] ?? const {}),
        ));
      }
    }

    return LlmResponse(
      content: message['content'] as String?,
      toolCalls: toolCalls,
    );
  }

  AppException _mapError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return NetworkException('The LLM timed out. Try again.', cause: e);
      case DioExceptionType.connectionError:
        return NetworkException(
          'Could not reach the LLM. Check the base URL and your connection.',
          cause: e,
        );
      case DioExceptionType.cancel:
        return NetworkException('The LLM request was cancelled.', cause: e);
      case DioExceptionType.badCertificate:
        return NetworkException('Could not verify the LLM\'s certificate.',
            cause: e);
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        break;
    }

    final status = e.response?.statusCode;
    if (status == 401 || status == 403) {
      return AuthException('The LLM rejected your API key. Check it in Settings.',
          cause: e);
    }
    if (status == 404) {
      return ApiException(
        'The LLM endpoint was not found. Check the base URL in Settings — '
        'it usually ends in /v1.',
        statusCode: status,
        cause: e,
      );
    }
    if (status == 429) {
      return NetworkException('The LLM is rate limiting. Try again shortly.',
          cause: e);
    }
    if (status != null && status >= 500) {
      return NetworkException('The LLM had a server error ($status). Try again.',
          cause: e);
    }

    final data = e.response?.data;
    var detail = '';
    if (data is Map) {
      final error = data['error'];
      if (error is Map && error['message'] is String) {
        detail = error['message'] as String;
      } else if (data['message'] is String) {
        detail = data['message'] as String;
      }
    }
    return ApiException(
      'The LLM request failed${status == null ? '' : ' ($status)'}. $detail'.trim(),
      statusCode: status,
      cause: e,
    );
  }
}
