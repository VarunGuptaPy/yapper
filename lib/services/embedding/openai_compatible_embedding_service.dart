import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../core/errors.dart';
import 'embedding_service.dart';

/// Embeddings from any provider that speaks OpenAI's `/embeddings` shape.
class OpenAiCompatibleEmbeddingService implements EmbeddingService {
  OpenAiCompatibleEmbeddingService({
    required String baseUrl,
    required String apiKey,
    required this.modelId,
    Dio? dio,
  })  : _baseUrl = _normalize(baseUrl),
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(minutes: 2),
              sendTimeout: const Duration(seconds: 60),
            )) {
    if (apiKey.isNotEmpty) {
      _dio.options.headers['Authorization'] = 'Bearer $apiKey';
    }
  }

  /// Providers rate-limit on request size, and a re-embed of a large notebook
  /// would otherwise send everything in one request.
  static const batchSize = 64;

  final String _baseUrl;
  final Dio _dio;

  @override
  final String modelId;

  static String _normalize(String raw) {
    var url = raw.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.endsWith('/embeddings')) {
      url = url.substring(0, url.length - '/embeddings'.length);
    }
    return url;
  }

  @override
  Future<List<Float32List>> embed(List<String> texts) async {
    if (texts.isEmpty) return const [];
    if (modelId.trim().isEmpty) {
      throw const AuthException('No embedding model set. Add one in Settings.');
    }

    final out = <Float32List>[];
    for (var i = 0; i < texts.length; i += batchSize) {
      final end = (i + batchSize).clamp(0, texts.length);
      out.addAll(await _embedBatch(texts.sublist(i, end)));
    }
    return out;
  }

  Future<List<Float32List>> _embedBatch(List<String> batch) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '$_baseUrl/embeddings',
        data: {
          'model': modelId,
          // An empty string is rejected by most providers; a single space is
          // accepted and embeds to something harmless.
          'input': [for (final t in batch) t.trim().isEmpty ? ' ' : t],
        },
      );

      final data = res.data?['data'];
      if (data is! List || data.length != batch.length) {
        throw ApiException(
          'The embedding provider returned '
          '${data is List ? data.length : 0} vectors for ${batch.length} inputs.',
        );
      }

      // The spec allows any order, so place each vector by its stated index.
      final vectors = List<Float32List?>.filled(batch.length, null);
      for (var i = 0; i < data.length; i++) {
        final item = data[i];
        if (item is! Map) throw const ApiException('Malformed embedding entry.');
        final index = item['index'] is int ? item['index'] as int : i;
        final raw = item['embedding'];
        if (raw is! List) {
          throw const ApiException('An embedding entry had no vector.');
        }
        if (index < 0 || index >= vectors.length) {
          throw const ApiException('An embedding entry had an out-of-range index.');
        }
        vectors[index] = Float32List.fromList(
          [for (final v in raw) (v as num).toDouble()],
        );
      }

      final result = <Float32List>[];
      for (final v in vectors) {
        if (v == null) {
          throw const ApiException('The provider skipped one of the inputs.');
        }
        result.add(v);
      }
      return result;
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  AppException _mapError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return NetworkException('The embedding provider timed out.', cause: e);
      case DioExceptionType.connectionError:
        return NetworkException(
          'Could not reach the embedding provider. Check the base URL.',
          cause: e,
        );
      case DioExceptionType.cancel:
        return NetworkException('The embedding request was cancelled.', cause: e);
      case DioExceptionType.badCertificate:
        return NetworkException('Could not verify the provider\'s certificate.',
            cause: e);
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        break;
    }

    final status = e.response?.statusCode;
    if (status == 401 || status == 403) {
      return AuthException(
        'The embedding provider rejected your API key. Check it in Settings.',
        cause: e,
      );
    }
    if (status == 404) {
      return ApiException(
        'The embeddings endpoint was not found. Check the base URL in '
        'Settings — it usually ends in /v1.',
        statusCode: status,
        cause: e,
      );
    }
    if (status == 429) {
      return NetworkException(
        'The embedding provider is rate limiting. Try again shortly.',
        cause: e,
      );
    }
    if (status != null && status >= 500) {
      return NetworkException('The embedding provider had a server error '
          '($status). Try again.', cause: e);
    }

    final data = e.response?.data;
    var detail = '';
    if (data is Map) {
      final error = data['error'];
      if (error is Map && error['message'] is String) {
        detail = error['message'] as String;
      }
    }
    return ApiException(
      'Embedding failed${status == null ? '' : ' ($status)'}. $detail'.trim(),
      statusCode: status,
      cause: e,
    );
  }
}

/// Used when the embedding provider is not configured yet, so search and chat
/// degrade to full-text only instead of crashing.
class UnconfiguredEmbeddingService implements EmbeddingService {
  const UnconfiguredEmbeddingService(this.message);

  final String message;

  @override
  String get modelId => '';

  @override
  Future<List<Float32List>> embed(List<String> texts) async =>
      throw AuthException(message);
}
