import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../data/db/connection.dart';
import '../data/db/database.dart';
import '../data/models/enums.dart';
import '../data/repositories/capture_repository.dart';
import '../data/repositories/chat_repository.dart';
import '../data/repositories/embedding_repository.dart';
import '../data/repositories/note_repository.dart';
import '../pipeline/capture_pipeline.dart';
import '../pipeline/pipeline_resumer.dart';
import '../search/embedding_indexer.dart';
import '../search/hybrid_search.dart';
import '../services/audio/recorder_service.dart';
import '../services/backup/backup_service.dart';
import '../services/chat/chat_agent.dart';
import '../services/chat/chat_tools.dart';
import '../services/connectivity_service.dart';
import '../services/embedding/embedding_service.dart';
import '../services/embedding/openai_compatible_embedding_service.dart';
import '../services/merge/merge_service.dart';
import '../services/notes/note_writer.dart';
import '../services/llm/llm_service.dart';
import '../services/llm/openai_compatible_llm_service.dart';
import '../services/settings/settings_model.dart';
import '../services/settings/settings_service.dart';
import '../services/structuring/structuring_service.dart';
import '../services/transcription/sarvam_common.dart';
import '../services/transcription/sarvam_transcription_service.dart';
import '../services/transcription/transcription_service.dart';
import '../services/unconfigured_services.dart';

// ---------------------------------------------------------------- database

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = openAppDatabase();
  ref.onDispose(() async {
    // Restore closes the database itself before swapping the file underneath
    // it, then invalidates this provider to reopen. Closing an already-closed
    // connection is not an error worth surfacing.
    try {
      await db.close();
    } catch (e) {
      logD('Database', 'close on dispose: $e');
    }
  });
  return db;
});

final noteRepositoryProvider = Provider<NoteRepository>(
  (ref) => NoteRepository(ref.watch(appDatabaseProvider)),
);

final captureRepositoryProvider = Provider<CaptureRepository>(
  (ref) => CaptureRepository(ref.watch(appDatabaseProvider)),
);

final embeddingRepositoryProvider = Provider<EmbeddingRepository>(
  (ref) => EmbeddingRepository(ref.watch(appDatabaseProvider)),
);

final chatRepositoryProvider = Provider<ChatRepository>(
  (ref) => ChatRepository(ref.watch(appDatabaseProvider)),
);

// ---------------------------------------------------------------- settings

final settingsServiceProvider = Provider<SettingsService>(
  (ref) => SettingsService(),
);

class SettingsNotifier extends AsyncNotifier<YapSettings> {
  @override
  Future<YapSettings> build() => ref.watch(settingsServiceProvider).load();

  Future<void> save(YapSettings settings) async {
    await ref.read(settingsServiceProvider).save(settings);
    state = AsyncData(settings);
  }
}

final settingsProvider =
    AsyncNotifierProvider<SettingsNotifier, YapSettings>(SettingsNotifier.new);

/// The loaded settings, or defaults while they are still being read.
final currentSettingsProvider = Provider<YapSettings>(
  (ref) => ref.watch(settingsProvider).value ?? const YapSettings(),
);

// ---------------------------------------------------------------- services

final connectivityProvider = Provider<ConnectivityService>(
  (ref) => ConnectivityPlusService(),
);

final transcriptionServiceProvider = Provider<TranscriptionService>((ref) {
  final settings = ref.watch(currentSettingsProvider);
  if (!settings.isTranscriptionConfigured) {
    return const UnconfiguredTranscriptionService(
      'Add your Sarvam API key in Settings, then tap Retry.',
    );
  }

  final http = SarvamHttp.forKey(settings.sarvamApiKey);
  ref.onDispose(http.close);

  return SarvamTranscriptionService(
    http: http,
    model: settings.sarvamModel,
    mode: settings.sarvamMode,
  );
});

final llmServiceProvider = Provider<LlmService>((ref) {
  final settings = ref.watch(currentSettingsProvider);
  if (!settings.isStructuringConfigured) {
    return UnconfiguredLlmService(
      settings.missingSetupMessage ?? 'Finish setting up the LLM in Settings.',
    );
  }
  return OpenAiCompatibleLlmService(
    baseUrl: settings.llmBaseUrl,
    apiKey: settings.llmApiKey,
    model: settings.llmModel,
  );
});

final structuringServiceProvider = Provider<StructuringService>(
  (ref) => StructuringService(ref.watch(llmServiceProvider)),
);

final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(database: ref.watch(appDatabaseProvider)),
);

final mergeServiceProvider = Provider<MergeService>(
  (ref) => MergeService(ref.watch(llmServiceProvider)),
);

final embeddingServiceProvider = Provider<EmbeddingService>((ref) {
  final settings = ref.watch(currentSettingsProvider);
  if (!settings.isEmbeddingConfigured) {
    return const UnconfiguredEmbeddingService(
      'Add your embedding base URL, key and model in Settings.',
    );
  }
  return OpenAiCompatibleEmbeddingService(
    baseUrl: settings.embeddingBaseUrl,
    apiKey: settings.embeddingApiKey,
    modelId: settings.embeddingModel,
  );
});

final embeddingIndexerProvider = Provider<EmbeddingIndexer>(
  (ref) => EmbeddingIndexer(
    notes: ref.watch(noteRepositoryProvider),
    embeddings: ref.watch(embeddingRepositoryProvider),
    service: ref.watch(embeddingServiceProvider),
  ),
);

final hybridSearchProvider = Provider<HybridSearch>(
  (ref) => HybridSearch(
    notes: ref.watch(noteRepositoryProvider),
    embeddings: ref.watch(embeddingRepositoryProvider),
    embeddingService: ref.watch(embeddingServiceProvider),
  ),
);

final noteWriterProvider = Provider<NoteWriter>(
  (ref) => NoteWriter(
    notes: ref.watch(noteRepositoryProvider),
    embeddings: ref.watch(embeddingRepositoryProvider),
    indexer: ref.watch(embeddingIndexerProvider),
    merger: ref.watch(mergeServiceProvider),
  ),
);

/// The runner is cached with the agent, so a note keeps the same reference
/// number for as long as the settings hold still. Answers are renumbered on
/// the way out regardless, so citations stay correct either way.
final chatAgentProvider = Provider<ChatAgent>(
  (ref) => ChatAgent(
    llm: ref.watch(llmServiceProvider),
    runner: ChatToolRunner(
      notes: ref.watch(noteRepositoryProvider),
      search: ref.watch(hybridSearchProvider),
    ),
  ),
);

final recorderServiceProvider = Provider<RecorderService>((ref) {
  final recorder = RecorderService();
  ref.onDispose(recorder.dispose);
  return recorder;
});

// ---------------------------------------------------------------- pipeline

final capturePipelineProvider = Provider<CapturePipeline>((ref) {
  final pipeline = CapturePipeline(
    captures: ref.watch(captureRepositoryProvider),
    notes: ref.watch(noteRepositoryProvider),
    transcription: ref.watch(transcriptionServiceProvider),
    structuring: ref.watch(structuringServiceProvider),
    connectivity: ref.watch(connectivityProvider),
    search: ref.watch(hybridSearchProvider),
    writer: ref.watch(noteWriterProvider),
    keytermsEnabled: () => ref.read(currentSettingsProvider).keytermsEnabled,
  );
  ref.onDispose(pipeline.dispose);
  return pipeline;
});

final pipelineResumerProvider = Provider<PipelineResumer>((ref) {
  final resumer = PipelineResumer(
    pipeline: ref.watch(capturePipelineProvider),
    captures: ref.watch(captureRepositoryProvider),
    connectivity: ref.watch(connectivityProvider),
  );
  ref.onDispose(resumer.dispose);
  return resumer;
});

// ---------------------------------------------------------------- queries

final recentCapturesProvider = StreamProvider<List<CaptureRow>>(
  (ref) => ref.watch(captureRepositoryProvider).watchRecent(),
);

/// The type chip selected on the Notes screen; null means "All".
class NoteTypeFilter extends Notifier<NoteType?> {
  @override
  NoteType? build() => null;

  void select(NoteType? type) => state = type;
}

final noteTypeFilterProvider =
    NotifierProvider<NoteTypeFilter, NoteType?>(NoteTypeFilter.new);

final notesProvider = StreamProvider<List<NoteRow>>((ref) {
  final filter = ref.watch(noteTypeFilterProvider);
  return ref.watch(noteRepositoryProvider).watchNotes(type: filter);
});

final noteProvider = StreamProvider.family<NoteRow?, String>(
  (ref, id) => ref.watch(noteRepositoryProvider).watchNote(id),
);

final noteCapturesProvider = FutureProvider.family<List<CaptureRow>, String>(
  (ref, id) => ref.watch(noteRepositoryProvider).capturesFor(id),
);

final noteVersionsProvider =
    FutureProvider.family<List<NoteVersionRow>, String>(
  (ref, id) => ref.watch(noteRepositoryProvider).versionsFor(id),
);

// ------------------------------------------------------------------- search

/// The text in the Notes search bar.
class NoteSearchQuery extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;
}

final noteSearchQueryProvider =
    NotifierProvider<NoteSearchQuery, String>(NoteSearchQuery.new);

/// Hybrid search results for the current query and type filter. Null query
/// means the list should show the plain, unfiltered stream instead.
final noteSearchResultsProvider =
    FutureProvider.autoDispose<List<SearchResult>>((ref) async {
  final query = ref.watch(noteSearchQueryProvider);
  if (query.trim().isEmpty) return const [];

  final type = ref.watch(noteTypeFilterProvider);
  return ref.watch(hybridSearchProvider).search(
        query,
        filters: SearchFilters(types: type == null ? const [] : [type]),
      );
});

// --------------------------------------------------------------------- chat

/// The thread on screen. Null means a fresh chat that has not been written
/// yet — no row exists until the first message is sent, so backing out of a
/// new chat leaves nothing behind.
class ActiveConversation extends Notifier<String?> {
  @override
  String? build() => null;

  void open(String id) => state = id;
  void startNew() => state = null;
}

final activeConversationProvider =
    NotifierProvider<ActiveConversation, String?>(ActiveConversation.new);

final chatConversationsProvider = StreamProvider<List<ConversationSummary>>(
  (ref) => ref.watch(chatRepositoryProvider).watchConversations(),
);

final chatMessagesProvider = StreamProvider<List<ChatMessageRow>>((ref) {
  final id = ref.watch(activeConversationProvider);
  if (id == null) return Stream.value(const <ChatMessageRow>[]);
  return ref.watch(chatRepositoryProvider).watchMessages(id);
});

// ------------------------------------------------------------------- people

final notePeopleProvider = FutureProvider.family<List<NoteRow>, String>(
  (ref, id) => ref.watch(noteRepositoryProvider).peopleFor(id),
);

final notesMentioningProvider = FutureProvider.family<List<NoteRow>, String>(
  (ref, id) => ref.watch(noteRepositoryProvider).notesMentioning(id),
);
