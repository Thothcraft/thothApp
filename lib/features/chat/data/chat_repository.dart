import '../../../core/api/brain_client.dart';

/// One turn of conversation as the Brain expects it.
class ChatTurn {
  const ChatTurn({required this.role, required this.content});
  final String role; // 'user' | 'assistant'
  final String content;

  Map<String, dynamic> toJson() => {'role': role, 'content': content};
}

/// An image/text/pdf the user attaches to a message.
class ChatAttachment {
  const ChatAttachment(
      {required this.name, required this.mime, required this.dataB64,});
  final String name;
  final String mime;
  final String dataB64;

  Map<String, dynamic> toJson() =>
      {'name': name, 'mime': mime, 'data_b64': dataB64};
}

/// Parsed Brain rich-answer.
class ChatAnswer {
  ChatAnswer({
    required this.answer,
    required this.widgets,
    required this.contextUsed,
    required this.attachments,
    this.modelTier,
    this.modelId,
  });

  factory ChatAnswer.fromJson(Map<String, dynamic> j) => ChatAnswer(
        answer: (j['answer'] ?? '') as String,
        widgets: (j['widgets'] as List?)
                ?.whereType<Map>()
                .map((w) => Map<String, dynamic>.from(w))
                .toList() ??
            const [],
        contextUsed: j['context_used'] is Map
            ? Map<String, dynamic>.from(j['context_used'] as Map)
            : null,
        attachments: (j['attachments'] as List?)
                ?.map((e) => '$e')
                .toList() ??
            const [],
        modelTier: j['model'] is Map ? '${j['model']['tier']}' : null,
        modelId: j['model'] is Map ? '${j['model']['id']}' : null,
      );

  final String answer;
  final List<Map<String, dynamic>> widgets;
  final Map<String, dynamic>? contextUsed;
  final List<String> attachments;
  final String? modelTier;
  final String? modelId;
}

/// POST /v1/chat — context-grounded rich answers, metered server-side.
class ChatRepository {
  Future<ChatAnswer> send(
    String message, {
    List<ChatTurn> history = const [],
    List<ChatAttachment> attachments = const [],
    bool includeContext = true,
    // '4'|'5'|'6' — numbered model picks (hub maps them to concrete
    // model ids); 'standard'/'advanced' still accepted for old clients.
    String model = '4',
  }) async {
    final res = await BrainClient.instance.postV1('/chat', body: {
      'message': message,
      'history': [for (final t in history) t.toJson()],
      'attachments': [for (final a in attachments) a.toJson()],
      'include_context': includeContext,
      'model': model,
    },);
    return ChatAnswer.fromJson(res);
  }

  /// GET /v1/chat/context — the bundle the assistant sees.
  Future<Map<String, dynamic>> contextBundle() =>
      BrainClient.instance.getV1('/chat/context');
}
