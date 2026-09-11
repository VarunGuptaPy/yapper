import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'settings_model.dart';

/// Reads and writes [YapSettings] through the platform keystore.
///
/// Every value lives in secure storage, not just the keys — it is one store to
/// reason about, and it keeps the model/base-URL choices out of any plaintext
/// preferences file.
class SettingsService {
  SettingsService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _kSarvamApiKey = 'sarvam_api_key';
  static const _kSarvamModel = 'sarvam_model';
  static const _kSarvamMode = 'sarvam_mode';
  static const _kLlmBaseUrl = 'llm_base_url';
  static const _kLlmApiKey = 'llm_api_key';
  static const _kLlmModel = 'llm_model';
  static const _kEmbeddingBaseUrl = 'embedding_base_url';
  static const _kEmbeddingApiKey = 'embedding_api_key';
  static const _kEmbeddingModel = 'embedding_model';

  Future<YapSettings> load() async {
    const defaults = YapSettings();
    final all = await _storage.readAll();

    String value(String key, String fallback) {
      final v = all[key];
      return (v == null || v.isEmpty) ? fallback : v;
    }

    return YapSettings(
      sarvamApiKey: value(_kSarvamApiKey, defaults.sarvamApiKey),
      sarvamModel: SarvamModel.fromWire(
          value(_kSarvamModel, defaults.sarvamModel.wire)),
      sarvamMode:
          SarvamMode.fromWire(value(_kSarvamMode, defaults.sarvamMode.wire)),
      llmBaseUrl: value(_kLlmBaseUrl, defaults.llmBaseUrl),
      llmApiKey: value(_kLlmApiKey, defaults.llmApiKey),
      llmModel: value(_kLlmModel, defaults.llmModel),
      embeddingBaseUrl: value(_kEmbeddingBaseUrl, defaults.embeddingBaseUrl),
      embeddingApiKey: value(_kEmbeddingApiKey, defaults.embeddingApiKey),
      embeddingModel: value(_kEmbeddingModel, defaults.embeddingModel),
    );
  }

  Future<void> save(YapSettings settings) async {
    await Future.wait([
      _write(_kSarvamApiKey, settings.sarvamApiKey),
      _write(_kSarvamModel, settings.sarvamModel.wire),
      _write(_kSarvamMode, settings.sarvamMode.wire),
      _write(_kLlmBaseUrl, settings.llmBaseUrl),
      _write(_kLlmApiKey, settings.llmApiKey),
      _write(_kLlmModel, settings.llmModel),
      _write(_kEmbeddingBaseUrl, settings.embeddingBaseUrl),
      _write(_kEmbeddingApiKey, settings.embeddingApiKey),
      _write(_kEmbeddingModel, settings.embeddingModel),
    ]);
  }

  Future<void> _write(String key, String value) =>
      value.isEmpty ? _storage.delete(key: key) : _storage.write(key: key, value: value);
}
