class Message {
  final String id;
  final String text;
  final String senderId;
  final String recipientId;
  final DateTime timestamp;
  final bool isSentByMe;

  Message({
    required this.id,
    required this.text,
    required this.senderId,
    required this.recipientId,
    required this.timestamp,
    required this.isSentByMe,
  });
}
