import 'llm_models.dart';

/// Chat completion with JSON mode and tool calling (SPEC.md §5).
abstract class LlmService {
  /// [jsonMode] asks the provider to constrain output to a JSON object.
  /// Callers must still validate the result — providers honour this to
  /// varying degrees.
  ///
  /// [tools] is used by the chat agent from Phase 2; the capture pipeline
  /// passes none.
  Future<LlmResponse> complete(
    List<ChatMessage> messages, {
    bool jsonMode = false,
    List<ToolDefinition> tools = const [],
    double temperature,
  });
}
