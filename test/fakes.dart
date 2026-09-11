import 'dart:io';
import 'dart:typed_data';

import 'package:yapapp/core/errors.dart';
import 'package:yapapp/services/embedding/embedding_service.dart';
import 'package:yapapp/data/models/transcript.dart';
import 'package:yapapp/services/connectivity_service.dart';
import 'package:yapapp/services/llm/llm_models.dart';
import 'package:yapapp/services/llm/llm_service.dart';
import 'package:yapapp/services/transcription/transcription_service.dart';

class FakeConnectivity implements ConnectivityService {
  FakeConnectivity({this.online = true});

  bool online;

  @override
  Future<bool> isOnline() async => online;

  @override
  Stream<bool> get onStatusChanged => const Stream<bool>.empty();
}

class FakeTranscriptionService implements TranscriptionService {
  FakeTranscriptionService({this.text = 'a transcript', this.error});

  String text;
  Object? error;
  int calls = 0;
  List<String> lastKeyterms = const [];
  Duration? lastDuration;

  @override
  Future<Transcript> transcribe(
    File audio, {
    List<String> keyterms = const [],
    Duration? duration,
  }) async {
    calls++;
    lastKeyterms = keyterms;
    lastDuration = duration;
    final err = error;
    if (err != null) throw err;
    return Transcript(text: text, languageCode: 'hi-IN');
  }
}

/// Replays scripted responses, one per call, so a test can describe an invalid
/// first answer followed by a valid retry.
class ScriptedLlmService implements LlmService {
  ScriptedLlmService(this.responses);

  final List<Object> responses;
  int calls = 0;
  final List<List<ChatMessage>> received = [];

  @override
  Future<LlmResponse> complete(
    List<ChatMessage> messages, {
    bool jsonMode = false,
    List<ToolDefinition> tools = const [],
    double temperature = 0.2,
  }) async {
    received.add(messages);
    if (calls >= responses.length) {
      throw StateError('ScriptedLlmService ran out of responses');
    }
    final next = responses[calls++];
    if (next is Exception) throw next;
    if (next is AppException) throw next;
    return LlmResponse(content: next as String);
  }
}

/// Deterministic pseudo-embeddings: a bag-of-words vector over a tiny fixed
/// vocabulary. Two texts sharing words come out similar, which is all the
/// search tests need — and it never touches the network.
class FakeEmbeddingService implements EmbeddingService {
  FakeEmbeddingService({this.modelId = 'fake-embed-v1', this.error});

  @override
  final String modelId;

  Object? error;
  int calls = 0;

  static const vocabulary = [
    'video', 'editing', 'movie', 'idea', 'person', 'food', 'rule',
    'goal', 'travel', 'music', 'code', 'wedding',
  ];

  @override
  Future<List<Float32List>> embed(List<String> texts) async {
    calls++;
    final err = error;
    if (err != null) throw err;

    return [
      for (final text in texts) _vectorFor(text),
    ];
  }

  Float32List _vectorFor(String text) {
    final lower = text.toLowerCase();
    final vector = Float32List(vocabulary.length + 1);
    for (var i = 0; i < vocabulary.length; i++) {
      vector[i] = lower.contains(vocabulary[i]) ? 1.0 : 0.0;
    }
    // A small constant keeps the vector non-zero for text with no known words,
    // so cosine stays defined.
    vector[vocabulary.length] = 0.05;
    return vector;
  }
}
