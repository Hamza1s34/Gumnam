class Contact {
  final String onionAddress;
  final String nickname;
  final String? lastMessage;
  final DateTime? lastMessageTime;
  final int unreadCount;

  Contact({
    required this.onionAddress,
    required this.nickname,
    this.lastMessage,
    this.lastMessageTime,
    this.unreadCount = 0,
  });
}
