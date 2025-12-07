import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:tor_messenger_ui/theme/app_theme.dart';

/// A bar that shows pinned messages at the top of the chat
class PinnedMessagesBar extends StatefulWidget {
  final List<dynamic> pinnedMessages;
  final void Function(String messageId) onPinnedMessageTap;
  final void Function(String messageId) onUnpin;

  const PinnedMessagesBar({
    super.key,
    required this.pinnedMessages,
    required this.onPinnedMessageTap,
    required this.onUnpin,
  });

  @override
  State<PinnedMessagesBar> createState() => _PinnedMessagesBarState();
}

class _PinnedMessagesBarState extends State<PinnedMessagesBar> {
  int _currentIndex = 0;
  bool _isExpanded = false;

  String _getMessagePreview(dynamic message) {
    if (message.msgType == 'image') return '📷 Image';
    if (message.msgType == 'audio') return '🎤 Voice message';
    if (message.msgType == 'file') return '📁 File';
    
    String text = message.text;
    // Remove forwarded prefix if present
    if (text.startsWith('⤵️ Forwarded\n')) {
      text = text.replaceFirst('⤵️ Forwarded\n', '');
    }
    // Remove reply prefix if present
    if (text.startsWith('↩️ ')) {
      final lines = text.split('\n\n');
      if (lines.length > 1) {
        text = lines.sublist(1).join('\n\n');
      }
    }
    return text.length > 50 ? '${text.substring(0, 50)}...' : text;
  }

  String _formatTime(int timestamp) {
    final time = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    return DateFormat('h:mm a').format(time); // 12-hour format with AM/PM
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pinnedMessages.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.sidebarBackground,
        border: Border(
          bottom: BorderSide(color: Colors.white.withOpacity(0.1)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Main pinned message bar
          InkWell(
            onTap: () {
              if (widget.pinnedMessages.length == 1) {
                widget.onPinnedMessageTap(widget.pinnedMessages[0].id);
              } else {
                setState(() => _isExpanded = !_isExpanded);
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  // Pin icon with count indicator
                  Stack(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.amber.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.push_pin,
                          size: 18,
                          color: Colors.amber,
                        ),
                      ),
                      if (widget.pinnedMessages.length > 1)
                        Positioned(
                          right: 0,
                          top: 0,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(
                              color: AppTheme.primaryPurple,
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              '${widget.pinnedMessages.length}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  // Message preview
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Text(
                              widget.pinnedMessages.length > 1
                                  ? 'Pinned Messages'
                                  : 'Pinned Message',
                              style: const TextStyle(
                                color: Colors.amber,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (widget.pinnedMessages.length > 1) ...[
                              const SizedBox(width: 8),
                              Text(
                                '(${_currentIndex + 1}/${widget.pinnedMessages.length})',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.5),
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _getMessagePreview(widget.pinnedMessages[_currentIndex]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Navigation arrows for multiple pinned messages
                  if (widget.pinnedMessages.length > 1) ...[
                    IconButton(
                      icon: const Icon(Icons.keyboard_arrow_up, size: 20),
                      color: AppTheme.textSecondary,
                      onPressed: () {
                        setState(() {
                          _currentIndex = (_currentIndex - 1 + widget.pinnedMessages.length) % 
                              widget.pinnedMessages.length;
                        });
                      },
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                    IconButton(
                      icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                      color: AppTheme.textSecondary,
                      onPressed: () {
                        setState(() {
                          _currentIndex = (_currentIndex + 1) % widget.pinnedMessages.length;
                        });
                      },
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                  // Go to message button
                  IconButton(
                    icon: const Icon(Icons.arrow_forward, size: 18),
                    color: AppTheme.primaryPurple,
                    onPressed: () => widget.onPinnedMessageTap(
                      widget.pinnedMessages[_currentIndex].id,
                    ),
                    tooltip: 'Go to message',
                  ),
                  // Expand/collapse button for multiple messages
                  if (widget.pinnedMessages.length > 1)
                    IconButton(
                      icon: Icon(
                        _isExpanded ? Icons.expand_less : Icons.expand_more,
                        size: 20,
                      ),
                      color: AppTheme.textSecondary,
                      onPressed: () => setState(() => _isExpanded = !_isExpanded),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                ],
              ),
            ),
          ),
          // Expanded list of all pinned messages
          if (_isExpanded && widget.pinnedMessages.length > 1)
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.pinnedMessages.length,
                itemBuilder: (context, index) {
                  final message = widget.pinnedMessages[index];
                  final isSelected = index == _currentIndex;
                  
                  return InkWell(
                    onTap: () {
                      setState(() {
                        _currentIndex = index;
                        _isExpanded = false;
                      });
                      widget.onPinnedMessageTap(message.id);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      color: isSelected ? Colors.white.withOpacity(0.05) : null,
                      child: Row(
                        children: [
                          Container(
                            width: 4,
                            height: 40,
                            decoration: BoxDecoration(
                              color: isSelected ? Colors.amber : Colors.transparent,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _getMessagePreview(message),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _formatTime(message.timestamp),
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.5),
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Unpin button
                          IconButton(
                            icon: const Icon(Icons.close, size: 16),
                            color: AppTheme.textSecondary,
                            onPressed: () => widget.onUnpin(message.id),
                            tooltip: 'Unpin',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
