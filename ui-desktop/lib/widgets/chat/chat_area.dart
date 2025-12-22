import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:tor_messenger_ui/services/chat_provider.dart';
import 'package:tor_messenger_ui/services/pinned_messages_manager.dart';
import 'package:tor_messenger_ui/theme/app_theme.dart';
import 'package:tor_messenger_ui/widgets/dialogs/contact_info_dialog.dart';
import 'package:tor_messenger_ui/widgets/chat/contact_info_view.dart';
import 'package:tor_messenger_ui/widgets/chat/message_bubble.dart';
import 'package:tor_messenger_ui/widgets/chat/message_reactions.dart';
import 'package:tor_messenger_ui/widgets/chat/pinned_messages_bar.dart';
import 'package:tor_messenger_ui/widgets/profile/my_profile_view.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'dart:io';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:async';
import 'dart:typed_data';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

class ChatArea extends StatefulWidget {
  const ChatArea({super.key});

  @override
  State<ChatArea> createState() => _ChatAreaState();
}

class _ChatAreaState extends State<ChatArea> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final _audioRecorder = AudioRecorder();
  final _audioPlayer = AudioPlayer();
  bool _isSending = false;
  bool _showEmoji = false;
  bool _isRecording = false;
  String? _recordingPath;
  Timer? _recordingTimer;
  Duration _recordingDuration = Duration.zero;

  // Reply state
  dynamic _replyingToMessage;
  
  // Forward state
  bool _isForwardMode = false;
  dynamic _messageToForward;

  // Pinned messages manager
  final _pinnedMessagesManager = PinnedMessagesManager();
  
  // Reactions manager
  final _reactionsManager = MessageReactionsManager();
  
  // Highlighted message for scroll-to-message feature
  String? _highlightedMessageId;
  Timer? _highlightTimer;

  // Audio Playback State
  String? _playingMessageId;
  Duration _totalDuration = Duration.zero;
  Duration _currentPosition = Duration.zero;
  PlayerState _playerState = PlayerState.stopped;
  StreamSubscription? _durationSubscription;
  StreamSubscription? _positionSubscription;
  StreamSubscription? _playerCompleteSubscription;
  StreamSubscription? _playerStateChangeSubscription;
  
  // Cache for decoded images to prevent re-decoding on rebuilds
  final Map<String, Uint8List> _imageCache = {};
  
  // Flag to prevent multiple audio player operations at once
  bool _isAudioOperationInProgress = false;

  @override
  void initState() {
    super.initState();
    
    // Load pinned messages
    _pinnedMessagesManager.load();
    
    // Load reactions
    _reactionsManager.load();
    
    _durationSubscription = _audioPlayer.onDurationChanged.listen((duration) {
      if (mounted && _totalDuration != duration) {
        setState(() => _totalDuration = duration);
      }
    });

    // Throttle position updates to reduce rebuilds
    _positionSubscription = _audioPlayer.onPositionChanged.listen((position) {
      // Only update if position difference is significant (200ms)
      if (mounted && (position.inMilliseconds - _currentPosition.inMilliseconds).abs() > 200) {
        setState(() => _currentPosition = position);
      }
    });

    _playerCompleteSubscription = _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playerState = PlayerState.stopped;
          _currentPosition = Duration.zero;
          _playingMessageId = null;
          _isAudioOperationInProgress = false;
        });
      }
    });

    _playerStateChangeSubscription = _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted && _playerState != state) {
        setState(() => _playerState = state);
      }
    });
  }

  @override
  void dispose() {
    // Cancel subscriptions first
    _durationSubscription?.cancel();
    _positionSubscription?.cancel();
    _playerCompleteSubscription?.cancel();
    _playerStateChangeSubscription?.cancel();
    _recordingTimer?.cancel();
    _highlightTimer?.cancel();
    
    // Then dispose resources
    _messageController.dispose();
    _scrollController.dispose();
    _audioRecorder.dispose();
    _audioPlayer.dispose();
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

  void _scrollToMessage(String messageId, List<dynamic> messages) {
    // Find the index of the message
    final index = messages.indexWhere((m) => m.id == messageId);
    if (index == -1) return;

    // Estimate scroll position (approximate height per message ~80px)
    final estimatedPosition = index * 80.0;

    // Scroll to the message
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        // Ensure we don't scroll past the max extent
        final targetPosition = estimatedPosition.clamp(
          0.0,
          _scrollController.position.maxScrollExtent,
        );

        _scrollController.animateTo(
          targetPosition,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
        );

        // Highlight the message temporarily
        setState(() {
          _highlightedMessageId = messageId;
        });

        // Remove highlight after 2 seconds
        _highlightTimer?.cancel();
        _highlightTimer = Timer(const Duration(seconds: 2), () {
          if (mounted) {
            setState(() {
              _highlightedMessageId = null;
            });
          }
        });
      }
    });
  }
  
  Future<void> _handleVoiceRecording() async {
    if (_isRecording) {
      // Stop recording and send
      try {
        _recordingTimer?.cancel();
        final path = await _audioRecorder.stop();
        setState(() {
          _isRecording = false;
          _recordingDuration = Duration.zero;
        });
        
        if (path != null) {
          final file = File(path);
          if (await file.exists()) {
             await context.read<ChatProvider>().sendFileMedia(file, 'audio');
             _scrollToBottom();
          }
        }
      } catch (e) {
        debugPrint('Error stopping recorder: $e');
        setState(() {
           _isRecording = false;
           _recordingDuration = Duration.zero;
        });
      }
    } else {
      // Start recording
      if (await _audioRecorder.hasPermission()) {
        final tempDir = await getTemporaryDirectory();
        final path = '${tempDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
        
        await _audioRecorder.start(const RecordConfig(), path: path);
        
        _recordingDuration = Duration.zero;
        _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          setState(() {
            _recordingDuration += const Duration(seconds: 1);
          });
        });

        setState(() {
          _isRecording = true;
          _recordingPath = path;
        });
      }
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  // Sanitize text to handle malformed UTF-16 characters
  String _sanitizeText(String text) {
    if (text.isEmpty) return ' '; // Return space to prevent empty string issues
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
      final result = buffer.toString();
      return result.isEmpty ? ' ' : result;
    } catch (e) {
      // If all else fails, return escaped version
      return text.replaceAll(RegExp(r'[^\x00-\x7F]'), '?');
    }
  }

  String _safeSubstring(String text, int start, [int? end]) {
    final sanitized = _sanitizeText(text);
    if (sanitized.isEmpty) return '?';
    final actualEnd = end != null ? (end > sanitized.length ? sanitized.length : end) : null;
    final actualStart = start >= sanitized.length ? 0 : start;
    return sanitized.substring(actualStart, actualEnd);
  }

  void _setReplyMessage(dynamic message) {
    setState(() {
      _replyingToMessage = message;
    });
  }

  void _cancelReply() {
    setState(() {
      _replyingToMessage = null;
    });
  }

  void _copyMessage(dynamic message) {
    final text = _sanitizeText(message.text);
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Message copied to clipboard')),
    );
  }

  void _confirmDeleteMessage(BuildContext context, dynamic message) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.sidebarBackground,
        title: const Text('Delete Message?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Are you sure you want to delete this message? This cannot be undone.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      await context.read<ChatProvider>().deleteMessage(message.id);
    }
  }

  Future<void> _handlePinMessage(dynamic message) async {
    final chatProvider = context.read<ChatProvider>();
    final contactAddress = chatProvider.selectedContact?.onionAddress;
    if (contactAddress == null) return;

    await _pinnedMessagesManager.togglePin(contactAddress, message.id);
    setState(() {}); // Refresh to show pin state

    final isPinned = _pinnedMessagesManager.isPinned(contactAddress, message.id);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(isPinned ? 'Message pinned' : 'Message unpinned'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  void _showForwardDialog(dynamic message) {
    final chatProvider = context.read<ChatProvider>();
    final contacts = chatProvider.contacts.where((c) => 
      c.onionAddress != 'web_messages_contact' &&
      c.onionAddress != chatProvider.selectedContact?.onionAddress
    ).toList();

    if (contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No other contacts to forward to')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.sidebarBackground,
        title: const Text('Forward to', style: TextStyle(color: Colors.white)),
        content: SizedBox(
          width: 300,
          height: 400,
          child: ListView.builder(
            itemCount: contacts.length,
            itemBuilder: (context, index) {
              final contact = contacts[index];
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppTheme.primaryPurple,
                  child: Text(
                    _safeSubstring(contact.nickname, 0, 1).toUpperCase(),
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
                title: Text(
                  _sanitizeText(contact.nickname),
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  '${_safeSubstring(contact.onionAddress, 0, 16)}...',
                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _forwardMessage(message, contact);
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Future<void> _forwardMessage(dynamic message, dynamic targetContact) async {
    final chatProvider = context.read<ChatProvider>();
    
    // Determine if this message was originally from someone else (received message)
    // If it was received (not sent by me), show "Forwarded" label
    // If it was sent by me, don't show "Forwarded" label
    final bool wasReceivedFromOther = !message.isSent;
    
    String forwardedText;
    if (wasReceivedFromOther) {
      // Message was received from another person - add forwarded indicator
      forwardedText = '⤵️ Forwarded\n${message.text}';
    } else {
      // Message was originally mine - just send as normal (no forwarded label)
      forwardedText = message.text;
    }
    
    try {
      // Save current contact
      final currentContact = chatProvider.selectedContact;
      
      // Switch to target contact, send, then switch back
      chatProvider.selectContact(targetContact);
      
      if (message.msgType == 'image' || message.msgType == 'audio' || message.msgType == 'file') {
        // For media, we need to forward as-is
        // Since the text contains base64 data, we forward with type indicator
        if (wasReceivedFromOther) {
          await chatProvider.sendNewMessage('⤵️ Forwarded message');
        }
        // Note: Media forwarding would need backend support to re-send the binary data
        // For now, just notify user
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Media forwarded (as notification)')),
        );
      } else {
        // Text message
        await chatProvider.sendNewMessage(forwardedText);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Message forwarded to ${_sanitizeText(targetContact.nickname)}')),
        );
      }
      
      // Switch back to original contact
      if (currentContact != null) {
        chatProvider.selectContact(currentContact);
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to forward: $e')),
      );
    }
  }

  String _getMessagePreview(dynamic message) {
    if (message.msgType == 'image') return '📷 Image';
    if (message.msgType == 'audio') return '🎤 Voice message';
    if (message.msgType == 'file') return '📁 File';
    final text = _sanitizeText(message.text);
    return text.length > 50 ? '${text.substring(0, 50)}...' : text;
  }

  void _showAttachmentMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppTheme.sidebarBackground,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image, color: Colors.blue),
              title: const Text('Image', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _pickFile(FileType.image, 'image');
              },
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file, color: Colors.orange),
              title: const Text('File', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _pickFile(FileType.any, 'file');
              },
            ),
            ListTile(
              leading: const Icon(Icons.audiotrack, color: Colors.purple),
              title: const Text('Audio File', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(context);
                _pickFile(FileType.audio, 'audio');
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFile(FileType pickerType, String msgType) async {
    try {
      final result = await FilePicker.platform.pickFiles(type: pickerType);
      if (result != null && result.files.isNotEmpty) {
        final file = File(result.files.single.path!);
        await context.read<ChatProvider>().sendFileMedia(file, msgType);
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error picking file: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 10),
            action: SnackBarAction(
              label: 'COPY',
              textColor: Colors.white,
              onPressed: () {
                // Clipboard requires `flutter/services.dart` which might not be imported
                // We will assume it is or add it if needed. 
                // Wait, I should check imports first. 
                // But `import 'package:flutter/services.dart';` is standard.
                // I'll add the import in a separate call if it fails, or just assume it for now.
                // Actually safer to read imports first? No, I'll gamble on `setData` being available via `Clipboard`.
                // Need to import services.dart.
                // I'll verify imports in a sec.
                Clipboard.setData(ClipboardData(text: e.toString()));
              },
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, chatProvider, child) {
        final selectedContact = chatProvider.selectedContact;
        
        // Show my profile view if requested
        if (chatProvider.showingMyProfile) {
          return MyProfileView(
            onBack: () => chatProvider.hideMyProfile(),
          );
        }

        if (selectedContact == null) {
          return _buildEmptyState();
        }

        // Show contact info view if requested (not for web messages)
        if (chatProvider.showingContactInfo && !chatProvider.isViewingWebMessages) {
          return ContactInfoView(
            onionAddress: selectedContact.onionAddress,
            onBack: () => chatProvider.hideContactInfo(),
          );
        }

        // Get pinned messages for this contact
        final pinnedIds = _pinnedMessagesManager.getPinnedMessageIds(selectedContact.onionAddress);
        final pinnedMessages = chatProvider.messages
            .where((m) => pinnedIds.contains(m.id))
            .toList();

        return Container(
          color: AppTheme.chatBackground,
          child: Column(
            children: [
              // Header
              _buildHeader(selectedContact, chatProvider.isViewingWebMessages),
              // Pinned Messages Bar
              if (pinnedMessages.isNotEmpty)
                PinnedMessagesBar(
                  pinnedMessages: pinnedMessages,
                  onPinnedMessageTap: (messageId) {
                    _scrollToMessage(messageId, chatProvider.messages);
                  },
                  onUnpin: (messageId) async {
                    await _pinnedMessagesManager.togglePin(selectedContact.onionAddress, messageId);
                    setState(() {});
                  },
                ),
              // Messages
              Expanded(
                child: _buildMessageList(chatProvider),
              ),
              // Input (hide for web messages)
              if (!chatProvider.isViewingWebMessages) ...[
                if (chatProvider.isBlocked(selectedContact.onionAddress))
                   _buildBlockedState(context, selectedContact)
                else
                   _buildInputArea(),
                if (_showEmoji && !chatProvider.isBlocked(selectedContact.onionAddress))
                  SizedBox(
                    height: 250,
                    child: EmojiPicker(
                      onEmojiSelected: (category, emoji) {
                        // Do nothing here, controller handling is enough usually
                      },
                      textEditingController: _messageController,
                      config: Config(
                        height: 256,
                        checkPlatformCompatibility: true,
                        emojiViewConfig: EmojiViewConfig(
                          // Tighter WhatsApp-like layout
                          emojiSizeMax: 21 * (Platform.isIOS ? 1.30 : 1.0),
                          columns: 10,
                          verticalSpacing: 0,
                          horizontalSpacing: 0,
                          backgroundColor: AppTheme.sidebarBackground,
                          recentsLimit: 50, // Increase recents limit
                          buttonMode: ButtonMode.CUPERTINO,
                        ),
                        skinToneConfig: const SkinToneConfig(
                          enabled: true,
                        ),
                        categoryViewConfig: const CategoryViewConfig(
                          initCategory: Category.RECENT,
                          backgroundColor: AppTheme.sidebarBackground,
                          indicatorColor: AppTheme.primaryPurple,
                          iconColor: Colors.grey,
                          iconColorSelected: AppTheme.primaryPurple,
                          backspaceColor: AppTheme.primaryPurple,
                          dividerColor: AppTheme.sidebarBackground,
                          tabBarHeight: 46,
                        ),
                        bottomActionBarConfig: const BottomActionBarConfig(
                          backgroundColor: AppTheme.sidebarBackground,
                          buttonColor: AppTheme.sidebarBackground,
                          buttonIconColor: Colors.grey,
                          showBackspaceButton: false, // Cleaner look
                          showSearchViewButton: true,
                        ),
                        searchViewConfig: const SearchViewConfig(
                          backgroundColor: AppTheme.sidebarBackground,
                          buttonIconColor: Colors.grey,
                          hintTextStyle: TextStyle(color: Colors.grey, fontSize: 16),
                          inputTextStyle: TextStyle(color: Colors.white, fontSize: 16),
                        ),
                      ),
                    ),
                  ),
              ] else
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
          // Make avatar clickable to show contact info (not for web messages)
          GestureDetector(
            onTap: isWebMessages ? null : () => context.read<ChatProvider>().showContactInfo(),
            child: CircleAvatar(
              backgroundColor: isWebMessages ? Colors.blue : AppTheme.primaryPurple,
              child: isWebMessages
                  ? const Icon(Icons.public, color: Colors.white)
                  : Text(
                      _safeSubstring(contact.nickname, 0, 1).toUpperCase(),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          // Make name clickable to show contact info (not for web messages)
          Expanded(
            child: GestureDetector(
              onTap: isWebMessages ? null : () => context.read<ChatProvider>().showContactInfo(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _sanitizeText(contact.nickname),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  Text(
                    isWebMessages 
                        ? 'Messages from your .onion web page'
                        : '${_safeSubstring(contact.onionAddress, 0, 24)}...',
                    style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                  ),
                ],
              ),
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
            onSelected: (value) async {
              final provider = context.read<ChatProvider>();
              switch (value) {
                case 'info':
                  if (!isWebMessages) {
                    showDialog(
                      context: context,
                      builder: (context) => ContactInfoDialog(onionAddress: contact.onionAddress),
                    );
                  }
                  break;
                case 'mute':
                   if (!isWebMessages) {
                      if (provider.isMuted(contact.onionAddress)) {
                        await provider.unmuteContact(contact.onionAddress);
                      } else {
                        await provider.muteContact(contact.onionAddress);
                      }
                   }
                   break;
                case 'block':
                   if (!isWebMessages) {
                      if (provider.isBlocked(contact.onionAddress)) {
                        await provider.unblockContact(contact.onionAddress);
                        // Go back to home/empty state often makes sense but usually we keep chat open until they leave
                      } else {
                        await provider.blockContact(contact.onionAddress);
                        provider.clearSelection(); // close chat if blocked
                      }
                   }
                   break;
                case 'export':
                   try {
                      await provider.exportChat(contact.onionAddress);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Chat exported to Downloads')),
                        );
                      }
                    } catch (e) {
                       if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Export failed: $e')),
                        );
                      }
                    }
                   break;
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
            itemBuilder: (context) {
              final provider = context.read<ChatProvider>();
              final isMuted = provider.isMuted(contact.onionAddress);
              final isBlocked = provider.isBlocked(contact.onionAddress);

              return [
              if (!isWebMessages) ...[
                const PopupMenuItem<String>(
                  value: 'info',
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: AppTheme.primaryPurple, size: 20),
                      SizedBox(width: 12),
                      Text('Contact Info', style: TextStyle(color: AppTheme.primaryPurple)),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'mute',
                  child: Row(
                    children: [
                      Icon(isMuted ? Icons.notifications_off : Icons.notifications_active, color: AppTheme.textSecondary, size: 20),
                      SizedBox(width: 12),
                      Text(isMuted ? 'Unmute' : 'Mute', style: const TextStyle(color: AppTheme.textPrimary)),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'block',
                  child: Row(
                    children: [
                      Icon(isBlocked ? Icons.check_circle : Icons.block, color: isBlocked ? Colors.green : Colors.redAccent, size: 20),
                      SizedBox(width: 12),
                      Text(isBlocked ? 'Unblock' : 'Block', style: TextStyle(color: isBlocked ? Colors.green : Colors.redAccent)),
                    ],
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'export',
                  child: Row(
                    children: [
                      Icon(Icons.download, color: AppTheme.primaryPurple, size: 20),
                      SizedBox(width: 12),
                      Text('Export Chat', style: TextStyle(color: AppTheme.primaryPurple)),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
              ],
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
            ];
            },
          ),
        ],
      ),
    );
  }

  void _confirmDeleteChat(BuildContext context, contact) async {
    final safeName = _sanitizeText(contact.nickname);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.sidebarBackground,
        title: const Text('Delete Chat?'),
        content: Text('Are you sure you want to delete the chat with $safeName?'),
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
    final safeName = _sanitizeText(contact.nickname);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.sidebarBackground,
        title: const Text('Clear Chat?'),
        content: Text('Are you sure you want to clear all messages with $safeName?'),
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
    final safeName = _sanitizeText(contact.nickname);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.sidebarBackground,
        title: const Text('Archive Chat?'),
        content: Text('Are you sure you want to archive the chat with $safeName?'),
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
      // Add key for better performance and to prevent unnecessary rebuilds
      key: ValueKey('message_list_${chatProvider.selectedContact?.onionAddress}'),
      itemBuilder: (context, index) {
        final message = messages[index];
        final isMe = message.isSent;
        
        // Check if this is a forwarded message (starts with forwarded indicator)
        final bool isForwarded = message.text.startsWith('⤵️ Forwarded');
        final String displayText = isForwarded 
            ? message.text.replaceFirst('⤵️ Forwarded\n', '')
            : message.text;
        
        // Check if message is pinned
        final contactAddress = chatProvider.selectedContact?.onionAddress ?? '';
        final isPinned = _pinnedMessagesManager.isPinned(contactAddress, message.id);
        final isHighlighted = _highlightedMessageId == message.id;
        final reaction = _reactionsManager.getReaction(message.id);
        
        return MessageBubble(
          key: ValueKey('msg_${message.id}'),
          message: message,
          isMe: isMe,
          isForwarded: isForwarded,
          displayText: displayText,
          isPinned: isPinned,
          isHighlighted: isHighlighted,
          reaction: reaction,
          buildMessageContent: _buildMessageContent,
          onReply: _setReplyMessage,
          onForward: _showForwardDialog,
          onCopy: _copyMessage,
          onDelete: (msg) => _confirmDeleteMessage(context, msg),
          onPin: _handlePinMessage,
          onReact: _handleReaction,
        );
      },
    );
  }

  Future<void> _handleReaction(dynamic message, String emoji) async {
    await _reactionsManager.setReaction(message.id, emoji);
    setState(() {}); // Refresh to show reaction
  }

  Widget _buildMessageContent(message, {String? displayText}) {
    if (message.msgType == 'image') {
      // Use cached image bytes if available to prevent re-decoding on rebuilds
      Uint8List? bytes = _imageCache[message.id];
      if (bytes == null) {
        try {
          bytes = base64Decode(message.text.replaceAll('\n', ''));
          _imageCache[message.id] = bytes;
        } catch (e) {
          return const Row(
            children: [
              Icon(Icons.error, color: Colors.red),
              SizedBox(width: 8),
              Text('Invalid Image', style: TextStyle(color: Colors.white)),
            ],
          );
        }
      }
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 300),
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true, // Prevents flickering on rebuilds
            errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.white),
          ),
        ),
      );
    } else if (message.msgType == 'audio') {
      final isPlaying = _playingMessageId == message.id && _playerState == PlayerState.playing;
      final isPaused = _playingMessageId == message.id && _playerState == PlayerState.paused;
      final isThisMessageActive = _playingMessageId == message.id;
      
      return Container(
        width: 260,
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            GestureDetector(
              onTap: _isAudioOperationInProgress ? null : () async {
                if (_isAudioOperationInProgress) return;
                
                setState(() => _isAudioOperationInProgress = true);
                
                try {
                  if (isPlaying) {
                    await _audioPlayer.pause();
                  } else if (isPaused) {
                    await _audioPlayer.resume();
                  } else {
                    // Stop previous if any
                    await _audioPlayer.stop();
                    
                    if (mounted) {
                      setState(() {
                        _playingMessageId = message.id;
                        _currentPosition = Duration.zero;
                        _totalDuration = Duration.zero;
                      });
                    }
                    
                    // Decode base64 to temp file
                    final bytes = base64Decode(message.text.replaceAll('\n', ''));
                    final tempDir = await getTemporaryDirectory();
                    final tempFile = File('${tempDir.path}/audio_${message.id}.m4a');
                    await tempFile.writeAsBytes(bytes);
                    
                    await _audioPlayer.play(DeviceFileSource(tempFile.path));
                  }
                } catch (e) {
                  debugPrint('Playback failed: $e');
                  if (mounted) {
                     ScaffoldMessenger.of(context).showSnackBar(
                       SnackBar(content: Text('Playback failed: $e')),
                     );
                     setState(() => _playingMessageId = null);
                  }
                } finally {
                  if (mounted) {
                    setState(() => _isAudioOperationInProgress = false);
                  }
                }
              },
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                padding: const EdgeInsets.all(8),
                child: _isAudioOperationInProgress && isThisMessageActive
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primaryPurple),
                      )
                    : Icon(
                        isPlaying ? Icons.pause : Icons.play_arrow,
                        color: AppTheme.primaryPurple,
                        size: 24,
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                      trackHeight: 4,
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white.withOpacity(0.3),
                      thumbColor: Colors.white,
                    ),
                    child: Slider(
                      value: (_playingMessageId == message.id) 
                          ? _currentPosition.inMilliseconds.toDouble() 
                          : 0.0,
                      max: (_playingMessageId == message.id && _totalDuration.inMilliseconds > 0)
                          ? _totalDuration.inMilliseconds.toDouble()
                          : 1.0,
                      onChanged: (value) async {
                        if (_playingMessageId == message.id) {
                          final position = Duration(milliseconds: value.toInt());
                          await _audioPlayer.seek(position);
                        }
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          (_playingMessageId == message.id) 
                              ? _formatDuration(_currentPosition) 
                              : '00:00',
                          style: const TextStyle(color: Colors.white, fontSize: 10),
                        ),
                        Text(
                          (_playingMessageId == message.id && _totalDuration.inMilliseconds > 0)
                              ? _formatDuration(_totalDuration)
                              : (_isRecording ? '00:00' : 'Voice Message'), // Fallback label
                          style: const TextStyle(color: Colors.white, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    } else if (message.msgType == 'file') {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file, color: Colors.white),
          const SizedBox(width: 8),
          Expanded(
             child: Text(
               'File Attachment', 
               style: const TextStyle(color: Colors.white, decoration: TextDecoration.underline),
               overflow: TextOverflow.ellipsis,
             ),
          ),
        ],
      );
    }
    
    // Default Text - use displayText if provided (for forwarded messages)
    final textToShow = displayText ?? message.text;
    
    // Check if this is a reply message (starts with ↩️)
    if (textToShow.startsWith('↩️ ')) {
      return _buildReplyMessageContent(textToShow, message.isSent);
    }
    
    return Text(
      _sanitizeText(textToShow),
      style: const TextStyle(color: Colors.white),
    );
  }

  /// Builds reply message with separated reply preview and actual message
  Widget _buildReplyMessageContent(String text, bool isSent) {
    // Parse reply format: ↩️ $replyPreview\n\n$actualMessage
    final parts = text.split('\n\n');
    String replyPreview = '';
    String actualMessage = '';
    
    if (parts.isNotEmpty) {
      // First part contains the reply preview (↩️ preview text)
      replyPreview = parts[0].replaceFirst('↩️ ', '');
      // Remaining parts are the actual message
      if (parts.length > 1) {
        actualMessage = parts.sublist(1).join('\n\n');
      }
    }
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Reply preview - dimmed and clickable
        GestureDetector(
          onTap: () => _scrollToReplyOriginal(replyPreview),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border(
                left: BorderSide(
                  color: isSent ? Colors.purple.withOpacity(0.6) : Colors.blue.withOpacity(0.6),
                  width: 3,
                ),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.reply,
                  size: 14,
                  color: Colors.white.withOpacity(0.5),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    replyPreview,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.6),
                      fontSize: 13,
                      fontStyle: FontStyle.italic,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Actual message
        if (actualMessage.isNotEmpty)
          Text(
            _sanitizeText(actualMessage),
            style: const TextStyle(color: Colors.white),
          ),
      ],
    );
  }

  /// Find and scroll to the original message that was replied to
  void _scrollToReplyOriginal(String replyPreview) {
    final chatProvider = context.read<ChatProvider>();
    final messages = chatProvider.messages;
    
    // Find the message that matches the reply preview
    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      final msgPreview = _getMessagePreview(msg);
      
      // Check if this message matches the reply preview
      if (msgPreview == replyPreview || msg.text.startsWith(replyPreview) || replyPreview.startsWith(msgPreview)) {
        // Scroll to this message
        _scrollToMessage(msg.id, messages);
        break;
      }
    }
  }

  Widget _buildInputArea() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Reply preview
        if (_replyingToMessage != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: AppTheme.sidebarBackground,
            child: Row(
              children: [
                Container(
                  width: 4,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppTheme.primaryPurple,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _replyingToMessage.isSent ? 'You' : 'Reply to',
                        style: const TextStyle(
                          color: AppTheme.primaryPurple,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        _getMessagePreview(_replyingToMessage),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  color: AppTheme.textSecondary,
                  onPressed: _cancelReply,
                ),
              ],
            ),
          ),
        // Input row
        Container(
          padding: const EdgeInsets.all(16),
          color: AppTheme.sidebarBackground,
          child: Row(
            children: [
              if (_isRecording) ...[
                 const Icon(Icons.mic, color: Colors.red),
                 const SizedBox(width: 8),
                 Text(
                   _formatDuration(_recordingDuration),
                   style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                 ),
                 const Spacer(),
                 const Text(
                   'Recording...', 
                   style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic)
                 ),
                 const Spacer(),
                 IconButton(
                   icon: const Icon(Icons.stop_circle, color: Colors.red),
                   onPressed: _handleVoiceRecording,
                 ),
              ] else ...[
                IconButton(
                  icon: Icon(
                    _showEmoji ? Icons.keyboard : Icons.emoji_emotions_outlined,
                    color: _showEmoji ? AppTheme.primaryPurple : null,
                  ),
                  onPressed: () {
                    setState(() {
                      _showEmoji = !_showEmoji;
                    });
                    if (_showEmoji) {
                      FocusScope.of(context).unfocus();
                    } else {
                      FocusScope.of(context).requestFocus();
                    }
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.attach_file),
                  onPressed: _showAttachmentMenu,
                ),
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    onSubmitted: (_) => _sendMessageWithReply(),
                    onTap: () {
                      if (_showEmoji) {
                        setState(() => _showEmoji = false);
                      }
                    },
                    decoration: InputDecoration(
                      hintText: _replyingToMessage != null ? 'Reply...' : 'Type a message',
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
                IconButton(
                  icon: const Icon(Icons.mic, color: null),
                  onPressed: _handleVoiceRecording,
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
                  onPressed: _isSending ? null : _sendMessageWithReply,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _sendMessageWithReply() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isSending) return;

    setState(() => _isSending = true);
    
    try {
      String messageToSend = text;
      
      // If replying, prepend reply reference
      if (_replyingToMessage != null) {
        final replyPreview = _getMessagePreview(_replyingToMessage);
        messageToSend = '↩️ $replyPreview\n\n$text';
      }
      
      await context.read<ChatProvider>().sendNewMessage(messageToSend);
      _messageController.clear();
      _cancelReply(); // Clear reply state
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

  Widget _buildBlockedState(BuildContext context, contact) {
    return Container(
      padding: const EdgeInsets.all(16),
      color: AppTheme.sidebarBackground,
      child: Column(
        children: [
          Text(
            'You blocked this contact',
            style: TextStyle(color: AppTheme.textSecondary.withOpacity(0.8), fontSize: 13),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TextButton(
                onPressed: () => _confirmDeleteChat(context, contact),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('Delete Chat'),
              ),
              const SizedBox(width: 16),
              ElevatedButton(
                onPressed: () => context.read<ChatProvider>().unblockContact(contact.onionAddress),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.sidebarBackground,
                  foregroundColor: AppTheme.primaryPurple,
                  side: const BorderSide(color: AppTheme.primaryPurple),
                ),
                child: const Text('Unblock'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
