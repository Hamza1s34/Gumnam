import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:tor_messenger_ui/services/chat_provider.dart';
import 'package:tor_messenger_ui/theme/app_theme.dart';

class ChatArea extends StatefulWidget {
  const ChatArea({super.key});

  @override
  State<ChatArea> createState() => _ChatAreaState();
}

class _ChatAreaState extends State<ChatArea> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  bool _isSending = false;

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isSending) return;

    setState(() => _isSending = true);
    
    try {
      await context.read<ChatProvider>().sendNewMessage(text);
      _messageController.clear();
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to send: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // Sanitize text to handle malformed UTF-16 characters
  String _sanitizeText(String text) {
    try {
      // Replace URL-encoded plus signs with spaces
      String cleaned = text.replaceAll('+', ' ');
      // Remove any invalid UTF-16 surrogate pairs
      final buffer = StringBuffer();
      for (int i = 0; i < cleaned.length; i++) {
        final codeUnit = cleaned.codeUnitAt(i);
        // Check if it's a valid character
        if (codeUnit >= 0x0000 && codeUnit <= 0xD7FF) {
          buffer.writeCharCode(codeUnit);
        } else if (codeUnit >= 0xE000 && codeUnit <= 0xFFFF) {
          buffer.writeCharCode(codeUnit);
        } else if (codeUnit >= 0xD800 && codeUnit <= 0xDBFF) {
          // High surrogate - check for valid low surrogate
          if (i + 1 < cleaned.length) {
            final nextCodeUnit = cleaned.codeUnitAt(i + 1);
            if (nextCodeUnit >= 0xDC00 && nextCodeUnit <= 0xDFFF) {
              buffer.writeCharCode(codeUnit);
              buffer.writeCharCode(nextCodeUnit);
              i++; // Skip next character
            }
          }
        }
        // Skip invalid characters silently
      }
      return buffer.toString();
    } catch (e) {
      // If all else fails, return escaped version
      return text.replaceAll(RegExp(r'[^\x00-\x7F]'), '?');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, chatProvider, child) {
        final selectedContact = chatProvider.selectedContact;
        
        if (selectedContact == null) {
          return _buildEmptyState();
        }

        return Container(
          color: AppTheme.chatBackground,
          child: Column(
            children: [
              // Header
              _buildHeader(selectedContact, chatProvider.isViewingWebMessages),
              // Messages
              Expanded(
                child: _buildMessageList(chatProvider),
              ),
              // Input (hide for web messages)
              if (!chatProvider.isViewingWebMessages)
                _buildInputArea()
              else
                _buildWebMessageNotice(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Container(
      color: AppTheme.chatBackground,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 80,
              color: AppTheme.textSecondary.withOpacity(0.5),
            ),
            const SizedBox(height: 24),
            const Text(
              'Welcome to Tor Messenger',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Select a contact or start a new chat',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(contact, bool isWebMessages) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: AppTheme.sidebarBackground,
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: isWebMessages ? Colors.blue : AppTheme.primaryPurple,
            child: isWebMessages
                ? const Icon(Icons.public, color: Colors.white)
                : Text(
                    contact.nickname.substring(0, 1).toUpperCase(),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  contact.nickname,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary,
                  ),
                ),
                Text(
                  isWebMessages 
                      ? 'Messages from your .onion web page'
                      : '${contact.onionAddress.substring(0, contact.onionAddress.length > 24 ? 24 : contact.onionAddress.length)}...',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => context.read<ChatProvider>().loadMessages(),
            tooltip: 'Refresh messages',
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            color: AppTheme.sidebarBackground,
            onSelected: (value) {
              switch (value) {
                case 'clear':
                  _confirmClearChat(context, contact);
                  break;
                case 'archive':
                  if (!isWebMessages) _confirmArchiveChat(context, contact);
                  break;
                case 'delete':
                  if (!isWebMessages) _confirmDeleteChat(context, contact);
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem<String>(
                value: 'clear',
                child: Row(
                  children: [
                    Icon(Icons.clear_all, color: Colors.orange, size: 20),
                    SizedBox(width: 12),
                    Text('Clear Chat', style: TextStyle(color: Colors.orange)),
                  ],
                ),
              ),
              if (!isWebMessages)
                const PopupMenuItem<String>(
                  value: 'archive',
                  child: Row(
                    children: [
                      Icon(Icons.archive, color: Colors.blue, size: 20),
                      SizedBox(width: 12),
                      Text('Archive Chat', style: TextStyle(color: Colors.blue)),
                    ],
                  ),
                ),
              if (!isWebMessages)
                const PopupMenuItem<String>(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete, color: Colors.red, size: 20),
                      SizedBox(width: 12),
                      Text('Delete Chat', style: TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  void _confirmDeleteChat(BuildContext context, contact) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.sidebarBackground,
        title: const Text('Delete Chat?'),
        content: Text('Are you sure you want to delete the chat with ${contact.nickname}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      context.read<ChatProvider>().deleteChatWithMessages(contact.onionAddress);
    }
  }

  void _confirmClearChat(BuildContext context, contact) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.sidebarBackground,
        title: const Text('Clear Chat?'),
        content: Text('Are you sure you want to clear all messages with ${contact.nickname}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.orange),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      context.read<ChatProvider>().clearChatMessages(contact.onionAddress);
    }
  }

  void _confirmArchiveChat(BuildContext context, contact) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.sidebarBackground,
        title: const Text('Archive Chat?'),
        content: Text('Are you sure you want to archive the chat with ${contact.nickname}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.blue),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      context.read<ChatProvider>().archiveChat(contact.onionAddress);
    }
  }

  Widget _buildMessageList(ChatProvider chatProvider) {
    final messages = chatProvider.messages;
    
    debugPrint('[ChatArea] Building message list with ${messages.length} messages');
    
    if (messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.message_outlined,
              size: 48,
              color: AppTheme.textSecondary.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            const Text(
              'No messages yet',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 8),
            const Text(
              'Send a message to start the conversation',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.all(20),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        final isMe = message.isSent;
        final time = DateTime.fromMillisecondsSinceEpoch(message.timestamp * 1000);
        
        return Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isMe ? AppTheme.sentMessage : AppTheme.receivedMessage,
              borderRadius: BorderRadius.circular(12),
            ),
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  _sanitizeText(message.text),
                  style: const TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      DateFormat('HH:mm').format(time),
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.7),
                        fontSize: 10,
                      ),
                    ),
                    if (isMe) ...[
                      const SizedBox(width: 4),
                      Icon(
                        message.isRead ? Icons.done_all : Icons.done,
                        size: 14,
                        color: message.isRead ? Colors.blue : Colors.white.withOpacity(0.7),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: AppTheme.sidebarBackground,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.emoji_emotions_outlined),
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.attach_file),
            onPressed: () {},
          ),
          Expanded(
            child: TextField(
              controller: _messageController,
              onSubmitted: (_) => _sendMessage(),
              decoration: InputDecoration(
                hintText: 'Type a message',
                filled: true,
                fillColor: AppTheme.receivedMessage,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: _isSending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send),
            onPressed: _isSending ? null : _sendMessage,
          ),
        ],
      ),
    );
  }

  Widget _buildWebMessageNotice() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: AppTheme.sidebarBackground,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.info_outline,
            color: Colors.blue.shade300,
            size: 20,
          ),
          const SizedBox(width: 8),
          Text(
            'Messages from web visitors appear here',
            style: TextStyle(
              color: Colors.blue.shade300,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}
