enum ChatRole { system, user, assistant, tool }

class ChatMessage {
  const ChatMessage({
    required this.role,
    this.content,
    this.toolCalls = const [],
    this.toolCallId,
  });

  const ChatMessage.system(String text)
      : role = ChatRole.system,
        content = text,
        toolCalls = const [],
        toolCallId = null;

  const ChatMessage.user(String text)
      : role = ChatRole.user,
        content = text,
        toolCalls = const [],
        toolCallId = null;

  const ChatMessage.assistant(String text)
      : role = ChatRole.assistant,
        content = text,
        toolCalls = const [],
        toolCallId = null;

  final ChatRole role;
  final String? content;
  final List<ToolCall> toolCalls;
  final String? toolCallId;

  Map<String, dynamic> toJson() => {
        'role': role.name,
        if (content != null) 'content': content,
        if (toolCalls.isNotEmpty)
          'tool_calls': [for (final c in toolCalls) c.toJson()],
        if (toolCallId != null) 'tool_call_id': toolCallId,
      };
}

/// A tool the model may call. Used from Phase 2 onward by the chat agent.
class ToolDefinition {
  const ToolDefinition({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;

  /// A JSON Schema object describing the arguments.
  final Map<String, dynamic> parameters;

  Map<String, dynamic> toJson() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': parameters,
        },
      };
}

class ToolCall {
  const ToolCall({
    required this.id,
    required this.name,
    required this.argumentsJson,
  });

  final String id;
  final String name;
  final String argumentsJson;

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'function',
        'function': {'name': name, 'arguments': argumentsJson},
      };
}

class LlmResponse {
  const LlmResponse({this.content, this.toolCalls = const []});

  final String? content;
  final List<ToolCall> toolCalls;

  bool get hasToolCalls => toolCalls.isNotEmpty;
}
