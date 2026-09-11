import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/errors.dart';
import '../../providers/providers.dart';
import '../../services/llm/openai_compatible_llm_service.dart';
import '../../search/embedding_indexer.dart';
import '../../services/embedding/openai_compatible_embedding_service.dart';
import '../../services/settings/settings_model.dart';
import 'backup_section.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _sarvamKey = TextEditingController();
  final _llmBaseUrl = TextEditingController();
  final _llmKey = TextEditingController();
  final _llmModel = TextEditingController();
  final _embeddingBaseUrl = TextEditingController();
  final _embeddingKey = TextEditingController();
  final _embeddingModel = TextEditingController();

  SarvamModel _model = SarvamModel.v4;
  SarvamMode _mode = SarvamMode.codemix;

  bool _loaded = false;
  bool _saving = false;
  String? _testResult;
  bool _testOk = false;

  ReembedProgress? _reembed;
  bool _reembedding = false;

  /// The embedding model the notes were last indexed with. Changing it makes
  /// every stored vector incomparable, so the re-embed action becomes urgent
  /// rather than optional (SPEC.md §8).
  String _indexedModel = '';

  @override
  void dispose() {
    for (final c in [
      _sarvamKey,
      _llmBaseUrl,
      _llmKey,
      _llmModel,
      _embeddingBaseUrl,
      _embeddingKey,
      _embeddingModel,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _hydrate(YapSettings settings) {
    if (_loaded) return;
    _loaded = true;
    _sarvamKey.text = settings.sarvamApiKey;
    _llmBaseUrl.text = settings.llmBaseUrl;
    _llmKey.text = settings.llmApiKey;
    _llmModel.text = settings.llmModel;
    _embeddingBaseUrl.text = settings.embeddingBaseUrl;
    _embeddingKey.text = settings.embeddingApiKey;
    _embeddingModel.text = settings.embeddingModel;
    _model = settings.sarvamModel;
    _mode = settings.sarvamMode;
    _indexedModel = settings.embeddingModel;
  }

  Future<void> _runReembed({required bool all}) async {
    setState(() {
      _reembedding = true;
      _reembed = null;
    });
    await ref.read(settingsProvider.notifier).save(_collect());

    final indexer = ref.read(embeddingIndexerProvider);
    final stream = all ? indexer.reembedAll() : indexer.indexMissing();

    await for (final progress in stream) {
      if (!mounted) return;
      setState(() => _reembed = progress);
    }
    if (mounted) {
      setState(() {
        _reembedding = false;
        _indexedModel = _embeddingModel.text.trim();
      });
    }
  }

  Future<void> _testEmbedding() async {
    setState(() {
      _testResult = 'Testing embeddings…';
      _testOk = false;
    });
    await ref.read(settingsProvider.notifier).save(_collect());

    final settings = _collect();
    if (!settings.isEmbeddingConfigured) {
      setState(() => _testResult =
          'Add the embedding base URL, key and model first.');
      return;
    }

    try {
      final vectors = await OpenAiCompatibleEmbeddingService(
        baseUrl: settings.embeddingBaseUrl,
        apiKey: settings.embeddingApiKey,
        modelId: settings.embeddingModel,
      ).embed(['hello']);
      if (!mounted) return;
      setState(() {
        _testResult = 'Connected. ${vectors.first.length} dimensions.';
        _testOk = true;
      });
    } on AppException catch (e) {
      if (mounted) setState(() => _testResult = e.message);
    } catch (e) {
      if (mounted) setState(() => _testResult = 'Failed: $e');
    }
  }

  YapSettings _collect() => YapSettings(
        sarvamApiKey: _sarvamKey.text.trim(),
        sarvamModel: _model,
        sarvamMode: _mode,
        llmBaseUrl: _llmBaseUrl.text.trim(),
        llmApiKey: _llmKey.text.trim(),
        llmModel: _llmModel.text.trim(),
        embeddingBaseUrl: _embeddingBaseUrl.text.trim(),
        embeddingApiKey: _embeddingKey.text.trim(),
        embeddingModel: _embeddingModel.text.trim(),
      );

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(settingsProvider.notifier).save(_collect());
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Settings saved')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Saves first, then makes one real call — so the thing being tested is
  /// exactly what the app will use.
  Future<void> _testLlm() async {
    setState(() {
      _testResult = 'Testing…';
      _testOk = false;
    });
    await ref.read(settingsProvider.notifier).save(_collect());

    final settings = _collect();
    if (!settings.isStructuringConfigured) {
      setState(() => _testResult = settings.missingSetupMessage);
      return;
    }

    final service = OpenAiCompatibleLlmService(
      baseUrl: settings.llmBaseUrl,
      apiKey: settings.llmApiKey,
      model: settings.llmModel,
    );
    try {
      await service.testConnection();
      if (mounted) {
        setState(() {
          _testResult = 'Connected to ${settings.llmModel}.';
          _testOk = true;
        });
      }
    } on AppException catch (e) {
      if (mounted) setState(() => _testResult = e.message);
    } catch (e) {
      if (mounted) setState(() => _testResult = 'Failed: $e');
    }
  }

  bool get _modelChanged =>
      _indexedModel.isNotEmpty &&
      _embeddingModel.text.trim() != _indexedModel;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('Save'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: settings.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load settings: $e')),
        data: (value) {
          _hydrate(value);
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
            children: [
              const _SectionTitle('Transcription'),
              _SecretField(
                controller: _sarvamKey,
                label: 'Sarvam API key',
                helper: 'From dashboard.sarvam.ai',
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<SarvamModel>(
                initialValue: _model,
                decoration: const InputDecoration(labelText: 'Model'),
                items: [
                  for (final m in SarvamModel.values)
                    DropdownMenuItem(value: m, child: Text(m.wire)),
                ],
                onChanged: (m) => setState(() => _model = m ?? _model),
              ),
              if (!_model.supportsKeyterms)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Keyterm prompting needs saaras:v4. On v3, the names of '
                    'your people notes are not sent, so they may be '
                    'transcribed phonetically.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              const SizedBox(height: 16),
              DropdownButtonFormField<SarvamMode>(
                initialValue: _mode,
                decoration: const InputDecoration(labelText: 'Output mode'),
                items: [
                  for (final m in SarvamMode.values)
                    DropdownMenuItem(value: m, child: Text(m.wire)),
                ],
                onChanged: (m) => setState(() => _mode = m ?? _mode),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _mode.description,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: 32),
              const _SectionTitle('Language model'),
              TextField(
                controller: _llmBaseUrl,
                decoration: const InputDecoration(
                  labelText: 'Base URL',
                  helperText: 'Any OpenAI-compatible endpoint, usually ending /v1',
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
              ),
              const SizedBox(height: 16),
              _SecretField(controller: _llmKey, label: 'API key'),
              const SizedBox(height: 16),
              TextField(
                controller: _llmModel,
                decoration: const InputDecoration(labelText: 'Model'),
                autocorrect: false,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  OutlinedButton(
                    onPressed: _testLlm,
                    child: const Text('Test connection'),
                  ),
                  const SizedBox(width: 12),
                  if (_testResult != null)
                    Expanded(
                      child: Text(
                        _testResult!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _testOk
                              ? theme.colorScheme.primary
                              : theme.colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 32),
              const _SectionTitle('Embeddings'),
              Text(
                'Powers meaning-based search, merge suggestions, and chat. '
                'Without it, search falls back to keywords only.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _embeddingBaseUrl,
                decoration: const InputDecoration(labelText: 'Base URL'),
                keyboardType: TextInputType.url,
                autocorrect: false,
              ),
              const SizedBox(height: 16),
              _SecretField(controller: _embeddingKey, label: 'API key'),
              const SizedBox(height: 16),
              TextField(
                controller: _embeddingModel,
                decoration: const InputDecoration(
                  labelText: 'Model',
                  helperText: 'e.g. text-embedding-3-small',
                ),
                autocorrect: false,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              if (_modelChanged)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    'The embedding model changed. Vectors from a different '
                    'model cannot be compared, so notes stay out of '
                    'meaning-based search until you re-embed them.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _reembedding ? null : _testEmbedding,
                    child: const Text('Test embeddings'),
                  ),
                  FilledButton.tonal(
                    onPressed: _reembedding
                        ? null
                        : () => _runReembed(all: _modelChanged),
                    child: Text(
                      _modelChanged ? 'Re-embed all notes' : 'Index new notes',
                    ),
                  ),
                ],
              ),
              if (_reembed != null) ...[
                const SizedBox(height: 12),
                _ReembedStatus(progress: _reembed!),
              ],
              const SizedBox(height: 32),
              const _SectionTitle('Backup'),
              const BackupSection(),
              const SizedBox(height: 32),
              Text(
                'Keys are stored in the Android keystore and never leave this '
                'device except as request headers to the services above. '
                'Yap has no server and collects nothing.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ReembedStatus extends StatelessWidget {
  const _ReembedStatus({required this.progress});

  final ReembedProgress progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (progress.error != null) {
      return Text(
        progress.error!,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.error),
      );
    }

    if (progress.total == 0) {
      return Text(
        'Every note is already indexed.',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.primary),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(value: progress.fraction),
        const SizedBox(height: 6),
        Text(
          progress.isComplete
              ? 'Indexed ${progress.total} note'
                  '${progress.total == 1 ? '' : 's'}.'
              : '${progress.done} of ${progress.total}…',
          style: theme.textTheme.bodySmall?.copyWith(
            color: progress.isComplete
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          label,
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
      );
}

/// An obscured field with a reveal toggle, so a mistyped key can be checked
/// without clearing it.
class _SecretField extends StatefulWidget {
  const _SecretField({
    required this.controller,
    required this.label,
    this.helper,
  });

  final TextEditingController controller;
  final String label;
  final String? helper;

  @override
  State<_SecretField> createState() => _SecretFieldState();
}

class _SecretFieldState extends State<_SecretField> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) => TextField(
        controller: widget.controller,
        obscureText: _obscured,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: widget.label,
          helperText: widget.helper,
          suffixIcon: IconButton(
            icon: Icon(_obscured
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined),
            onPressed: () => setState(() => _obscured = !_obscured),
          ),
        ),
      );
}
