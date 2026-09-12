/// Sarvam output modes. See SPEC.md §14.2.
enum SarvamMode {
  codemix('codemix', 'Code-mixed (English words in English, Indic in native script)'),
  translit('translit', 'Romanized (everything in Latin script)'),
  transcribe('transcribe', 'Original language'),
  translate('translate', 'Translated to English'),
  verbatim('verbatim', 'Verbatim, including fillers');

  const SarvamMode(this.wire, this.description);

  final String wire;
  final String description;

  static SarvamMode fromWire(String value) => SarvamMode.values.firstWhere(
        (m) => m.wire == value,
        orElse: () => SarvamMode.codemix,
      );
}

/// Sarvam speech-to-text models.
///
/// Keyterm prompting is documented as `saaras:v4` only, which is why v4 is the
/// default even though the original spec named v3 (SPEC.md §14.1, D2).
enum SarvamModel {
  v4('saaras:v4', supportsKeyterms: true),
  v3('saaras:v3', supportsKeyterms: false);

  const SarvamModel(this.wire, {required this.supportsKeyterms});

  final String wire;
  final bool supportsKeyterms;

  static SarvamModel fromWire(String value) => SarvamModel.values.firstWhere(
        (m) => m.wire == value,
        orElse: () => SarvamModel.v4,
      );
}

/// Everything configured on the Settings screen.
///
/// Held in `flutter_secure_storage`; nothing here is ever written to the
/// database, a log, or a backup file in plaintext.
class YapSettings {
  const YapSettings({
    this.sarvamApiKey = '',
    this.sarvamModel = SarvamModel.v4,
    this.sarvamMode = SarvamMode.codemix,
    this.keytermsEnabled = false,
    this.llmBaseUrl = 'https://api.openai.com/v1',
    this.llmApiKey = '',
    this.llmModel = '',
    this.embeddingBaseUrl = 'https://api.openai.com/v1',
    this.embeddingApiKey = '',
    this.embeddingModel = '',
  });

  final String sarvamApiKey;
  final SarvamModel sarvamModel;
  final SarvamMode sarvamMode;

  /// Whether the names of your people are sent to Sarvam to bias recognition.
  ///
  /// Off by default. Biasing cuts both ways, and on real recordings it cut the
  /// wrong way twice: unrelated words were replaced by known names — "Madaari"
  /// came back as "Parvesh Rawal". Known-name spelling is handled by the
  /// structuring model instead, which can tell a film title from a person.
  final bool keytermsEnabled;

  final String llmBaseUrl;
  final String llmApiKey;
  final String llmModel;

  /// Used from Phase 2 onward for hybrid search and chat.
  final String embeddingBaseUrl;
  final String embeddingApiKey;
  final String embeddingModel;

  bool get isTranscriptionConfigured => sarvamApiKey.trim().isNotEmpty;

  bool get isStructuringConfigured =>
      llmBaseUrl.trim().isNotEmpty &&
      llmApiKey.trim().isNotEmpty &&
      llmModel.trim().isNotEmpty;

  bool get isEmbeddingConfigured =>
      embeddingBaseUrl.trim().isNotEmpty &&
      embeddingApiKey.trim().isNotEmpty &&
      embeddingModel.trim().isNotEmpty;

  /// True when a recording can go all the way to a review card.
  bool get isCaptureReady => isTranscriptionConfigured && isStructuringConfigured;

  /// A short, user-facing explanation of what is still missing.
  String? get missingSetupMessage {
    final missing = <String>[];
    if (!isTranscriptionConfigured) missing.add('Sarvam API key');
    if (llmBaseUrl.trim().isEmpty) missing.add('LLM base URL');
    if (llmApiKey.trim().isEmpty) missing.add('LLM API key');
    if (llmModel.trim().isEmpty) missing.add('LLM model');
    if (missing.isEmpty) return null;
    if (missing.length == 1) return 'Add your ${missing.single} in Settings.';
    return 'Add your ${missing.sublist(0, missing.length - 1).join(', ')} '
        'and ${missing.last} in Settings.';
  }

  YapSettings copyWith({
    String? sarvamApiKey,
    SarvamModel? sarvamModel,
    SarvamMode? sarvamMode,
    bool? keytermsEnabled,
    String? llmBaseUrl,
    String? llmApiKey,
    String? llmModel,
    String? embeddingBaseUrl,
    String? embeddingApiKey,
    String? embeddingModel,
  }) =>
      YapSettings(
        sarvamApiKey: sarvamApiKey ?? this.sarvamApiKey,
        sarvamModel: sarvamModel ?? this.sarvamModel,
        sarvamMode: sarvamMode ?? this.sarvamMode,
        keytermsEnabled: keytermsEnabled ?? this.keytermsEnabled,
        llmBaseUrl: llmBaseUrl ?? this.llmBaseUrl,
        llmApiKey: llmApiKey ?? this.llmApiKey,
        llmModel: llmModel ?? this.llmModel,
        embeddingBaseUrl: embeddingBaseUrl ?? this.embeddingBaseUrl,
        embeddingApiKey: embeddingApiKey ?? this.embeddingApiKey,
        embeddingModel: embeddingModel ?? this.embeddingModel,
      );
}
