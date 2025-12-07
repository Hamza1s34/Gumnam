import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:tor_messenger_ui/theme/app_theme.dart';
import 'package:tor_messenger_ui/widgets/chat/message_reactions.dart';

/// A message bubble widget with hover menu support
class MessageBubble extends StatefulWidget {
  final dynamic message;
  final bool isMe;
  final bool isForwarded;
  final String displayText;
  final bool isPinned;
  final bool isHighlighted;
  final String? reaction; // Single reaction emoji
  final Widget Function(dynamic message, {String? displayText}) buildMessageContent;
  final void Function(dynamic message) onReply;
  final void Function(dynamic message) onForward;
  final void Function(dynamic message) onCopy;
  final void Function(dynamic message) onDelete;
  final void Function(dynamic message) onPin;
  final void Function(dynamic message, String emoji) onReact;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMe,
    required this.isForwarded,
    required this.displayText,
    required this.isPinned,
    this.isHighlighted = false,
    this.reaction,
    required this.buildMessageContent,
    required this.onReply,
    required this.onForward,
    required this.onCopy,
    required this.onDelete,
    required this.onPin,
    required this.onReact,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  bool _isHovering = false;
  final GlobalKey _menuButtonKey = GlobalKey();

  void _showMessageMenu() {
    final RenderBox? renderBox = _menuButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final position = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy + size.height,
        position.dx + size.width,
        position.dy,
      ),
      color: AppTheme.sidebarBackground,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      items: [
        _buildMenuItem(Icons.emoji_emotions_outlined, 'React', 'react'),
        _buildMenuItem(Icons.reply, 'Reply', 'reply'),
        _buildMenuItem(Icons.forward, 'Forward', 'forward'),
        if (widget.message.msgType == null || widget.message.msgType == 'text')
          _buildMenuItem(Icons.copy, 'Copy', 'copy'),
        _buildMenuItem(
          widget.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
          widget.isPinned ? 'Unpin' : 'Pin',
          'pin',
        ),
        const PopupMenuDivider(),
        _buildMenuItem(Icons.delete_outline, 'Delete', 'delete', isDestructive: true),
      ],
    ).then((value) {
      if (value == null) return;
      switch (value) {
        case 'react':
          _showReactionPicker();
          break;
        case 'reply':
          widget.onReply(widget.message);
          break;
        case 'forward':
          widget.onForward(widget.message);
          break;
        case 'copy':
          widget.onCopy(widget.message);
          break;
        case 'pin':
          widget.onPin(widget.message);
          break;
        case 'delete':
          widget.onDelete(widget.message);
          break;
      }
    });
  }

  void _showReactionPicker() {
    showReactionPicker(
      context,
      currentReaction: widget.reaction,
      onReactionSelected: (emoji) {
        widget.onReact(widget.message, emoji);
      },
    );
  }

  PopupMenuItem<String> _buildMenuItem(IconData icon, String label, String value, {bool isDestructive = false}) {
    final color = isDestructive ? Colors.red : Colors.white;
    return PopupMenuItem<String>(
      value: value,
      height: 40,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: color, fontSize: 14)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final time = DateTime.fromMillisecondsSinceEpoch(widget.message.timestamp * 1000);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: Column(
        crossAxisAlignment: widget.isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Message row with menu buttons
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Menu button on left for received messages
              if (!widget.isMe && _isHovering)
                _buildMenuButton()
              else if (!widget.isMe)
                const SizedBox(width: 32),

              // Message content
              Flexible(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: widget.isHighlighted 
                              ? (widget.isMe 
                                  ? AppTheme.sentMessage.withOpacity(0.9)
                                  : AppTheme.receivedMessage.withOpacity(0.9))
                              : (widget.isMe ? AppTheme.sentMessage : AppTheme.receivedMessage),
                          borderRadius: BorderRadius.circular(12),
                          border: widget.isHighlighted
                              ? Border.all(color: Colors.blue.withOpacity(0.8), width: 2)
                              : widget.isPinned
                                  ? Border.all(color: Colors.amber.withOpacity(0.5), width: 1)
                                  : null,
                          boxShadow: widget.isHighlighted
                              ? [
                                  BoxShadow(
                                    color: Colors.blue.withOpacity(0.3),
                                    blurRadius: 8,
                                    spreadRadius: 2,
                                  ),
                                ]
                              : null,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Pinned indicator
                            if (widget.isPinned) ...[
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.push_pin,
                                    size: 12,
                                    color: Colors.amber.withOpacity(0.8),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Pinned',
                                    style: TextStyle(
                                      color: Colors.amber.withOpacity(0.8),
                                      fontSize: 11,
                                      fontStyle: FontStyle.italic,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                            ],
                            // Forwarded indicator
                            if (widget.isForwarded) ...[
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.forward,
                                    size: 12,
                                    color: Colors.white.withOpacity(0.6),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Forwarded',
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.6),
                                      fontSize: 11,
                                      fontStyle: FontStyle.italic,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                            ],
                            // Message content
                            widget.buildMessageContent(
                              widget.message,
                              displayText: widget.isForwarded ? widget.displayText : null,
                            ),
                            const SizedBox(height: 4),
                            // Time and read status
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  DateFormat('h:mm a').format(time),
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.7),
                                    fontSize: 10,
                                  ),
                                ),
                                if (widget.isMe) ...[
                                  const SizedBox(width: 4),
                                  Icon(
                                    widget.message.isRead ? Icons.done_all : Icons.done,
                                    size: 14,
                                    color: widget.message.isRead
                                        ? Colors.blue
                                        : Colors.white.withOpacity(0.7),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                      // Reaction displayed at bottom-right corner on bubble (transparent)
                      if (widget.reaction != null)
                        Positioned(
                          bottom: -10,
                          right: widget.isMe ? 8 : null,
                          left: widget.isMe ? null : 8,
                          child: GestureDetector(
                            onTap: _showReactionPicker,
                            child: Text(
                              widget.reaction!,
                              style: const TextStyle(fontSize: 18),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),

              // Menu button on right for sent messages
              if (widget.isMe && _isHovering)
                _buildMenuButton()
              else if (widget.isMe)
                const SizedBox(width: 32),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMenuButton() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: _menuButtonKey,
          onTap: _showMessageMenu,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: AppTheme.sidebarBackground.withOpacity(0.8),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(
              Icons.more_vert,
              size: 20,
              color: AppTheme.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
