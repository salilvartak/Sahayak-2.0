class ConversationTurn {
  final String query;
  final String response;
  final DateTime timestamp;
  final String? imagePath;

  ConversationTurn({
    required this.query,
    required this.response,
    required this.timestamp,
    this.imagePath,
  });

  Map<String, dynamic> toJson() => {
    'query': query,
    'response': response,
    'timestamp': timestamp.toIso8601String(),
    'imagePath': imagePath,
  };

  factory ConversationTurn.fromJson(Map<String, dynamic> json) => ConversationTurn(
    query: json['query'],
    response: json['response'],
    timestamp: DateTime.parse(json['timestamp']),
    imagePath: json['imagePath'],
  );
}
