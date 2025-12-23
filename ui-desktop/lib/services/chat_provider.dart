import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:gumnam/generated/rust_bridge/api.dart';
import 'package:gumnam/generated/rust_bridge/api.dart' as api show deleteMessage;
import 'package:local_notifier/local_notifier.dart';
import 'package:window_manager/window_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

class ChatProvider extends ChangeNotifier {
  List<ContactInfo> _contacts = [];
  List<ContactInfo> _archivedContacts = [];
  List<MessageInfo> _messages = [];
  ContactInfo? _selectedContact;
  bool _isLoading = false;
  int _webMessageCount = 0;
  Timer? _pollTimer;
  Timer? _contactRefreshTimer;
  bool _showingContactInfo = false;
  bool _showingMyProfile = false;
  final Map<String, int> _unreadCounts = {};  // Track unread messages per contact
  final Map<String, int> _lastMessageCounts = {};  // Track last known received message counts
  final Map<String, String> _lastMessageTexts = {}; // Track last message text for preview
  
  // Track last known contact count to detect new contacts
  int _lastKnownContactCount = 0;
  
  // Flag to prevent multiple simultaneous updates
  bool _isUpdating = false;
  
  // Settings & Privacy State
  List<String> _blockedContacts = [];
  Map<String, int> _blockedSince = {}; // Track when a contact was blocked
  List<String> _mutedContacts = [];
  bool _notificationsEnabled = true;
  bool _soundEnabled = true;

  List<ContactInfo> get contacts => _contacts;
  List<ContactInfo> get archivedContacts => _archivedContacts;
  List<MessageInfo> get messages => _messages;
  ContactInfo? get selectedContact => _selectedContact;
  bool get isLoading => _isLoading;
  int get webMessageCount => _webMessageCount;
  bool get showingContactInfo => _showingContactInfo;
  bool get showingMyProfile => _showingMyProfile;
  
  // Settings Getters
  List<String> get blockedContacts => _blockedContacts;
  List<String> get mutedContacts => _mutedContacts;
  bool get notificationsEnabled => _notificationsEnabled;
  bool get soundEnabled => _soundEnabled;

  ChatProvider() {
    _loadSettings();
  }

  Future<void> _loadSettings() async {    
    final prefs = await SharedPreferences.getInstance();
    _blockedContacts = prefs.getStringList('blocked_contacts') ?? [];
    
    final blockedSinceString = prefs.getString('blocked_since');
    if (blockedSinceString != null) {
      try {
        final Map<String, dynamic> decoded = jsonDecode(blockedSinceString);
        _blockedSince = decoded.map((k, v) => MapEntry(k, v as int));
      } catch (e) {
        _blockedSince = {};
      }
    }

    _mutedContacts = prefs.getStringList('muted_contacts') ?? [];
    _notificationsEnabled = prefs.getBool('notifications_enabled') ?? true;
    _soundEnabled = prefs.getBool('sound_enabled') ?? true;
    notifyListeners();
  }
  
  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('blocked_contacts', _blockedContacts);
    await prefs.setString('blocked_since', jsonEncode(_blockedSince));
    await prefs.setStringList('muted_contacts', _mutedContacts);
    await prefs.setBool('notifications_enabled', _notificationsEnabled);
    await prefs.setBool('sound_enabled', _soundEnabled);
  }

  // Settings Actions
  Future<void> toggleNotifications(bool value) async {
    _notificationsEnabled = value;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> toggleSound(bool value) async {
    _soundEnabled = value;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> blockContact(String onionAddress) async {
    if (!_blockedContacts.contains(onionAddress)) {
      _blockedContacts.add(onionAddress);
      // Record timestamp to hide messages received AFTER this point
      _blockedSince[onionAddress] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await _saveSettings();
      notifyListeners();
    }
  }

  Future<void> unblockContact(String onionAddress) async {
    if (_blockedContacts.contains(onionAddress)) {
      _blockedContacts.remove(onionAddress);
      _blockedSince.remove(onionAddress);
      await _saveSettings();
      notifyListeners();
      // Reload messages to show previously hidden ones
      if (_selectedContact?.onionAddress == onionAddress) {
        await loadMessages();
      }
    }
  }

  bool isBlocked(String onionAddress) => _blockedContacts.contains(onionAddress);

  Future<void> muteContact(String onionAddress) async {
    if (!_mutedContacts.contains(onionAddress)) {
      _mutedContacts.add(onionAddress);
      await _saveSettings();
      notifyListeners();
    }
  }

  Future<void> unmuteContact(String onionAddress) async {
    if (_mutedContacts.contains(onionAddress)) {
      _mutedContacts.remove(onionAddress);
      await _saveSettings();
      notifyListeners();
    }
  }

  bool isMuted(String onionAddress) => _mutedContacts.contains(onionAddress);
  
  // Storage & Export
  Future<Map<String, int>> getStorageUsage() async {
    try {
      final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home == null) return {'total': 0, 'chat': 0, 'system': 0};
      
      final appDir = Directory('$home/.tor_messenger');
      if (!await appDir.exists()) return {'total': 0, 'chat': 0, 'system': 0};

      int chatSize = 0;
      int systemSize = 0;
      
      // Calculate DB size (chat data)
      final dbFile = File('${appDir.path}/messages.db');
      if (await dbFile.exists()) {
        chatSize += await dbFile.length();
      }
      
      // Calculate System size (everything else)
      await for (final entity in appDir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          if (entity.path.endsWith('messages.db')) continue;
          systemSize += await entity.length();
        }
      }
      
      return {
        'total': chatSize + systemSize,
        'chat': chatSize,
        'system': systemSize,
      };
    } catch (e) {
      debugPrint("Error calculating storage: $e");
      return {'total': 0, 'chat': 0, 'system': 0};
    }
  }

  Future<void> clearSystemCache() async {
    try {
      final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home == null) return;
      
      final torDataDir = Directory('$home/.tor_messenger/tor_data');
      if (await torDataDir.exists()) {
        // We delete contents but not the directory itself to be safe, 
        // or just delete the hidden_service directory if we want to reset identity (NONO, we want cache).
        // Actually, deleting 'tor_data' might reset identity if keys are in there.
        // Rust config says keys are in ~/.tor_messenger/keys.
        // tor_data contains 'hidden_service' (hostname/keys) and cached tor consensus.
        // We should ONLY delete cached files, not the hidden_service directory!
        
        await for (final entity in torDataDir.list(followLinks: false)) {
          // Preserve hidden_service directory to keep identity
          if (entity.path.endsWith('hidden_service')) continue;
          
          try {
             await entity.delete(recursive: true);
          } catch (e) {
            debugPrint('Could not delete ${entity.path}: $e');
          }
        }
      }
      notifyListeners();
    } catch (e) {
       debugPrint("Error clearing system cache: $e");
       rethrow;
    }
  }

  Future<void> exportChat(String onionAddress) async {
    try {
      final downloadDir = await getDownloadsDirectory();
      if (downloadDir == null) return;
      
      final messages = await getMessages(contactOnion: onionAddress, limit: 10000);
      final contact = _contacts.firstWhere((c) => c.onionAddress == onionAddress, orElse: () => ContactInfo(onionAddress: onionAddress, nickname: "Unknown"));
      
      final sb = StringBuffer();
      sb.writeln("Chat Export with ${contact.nickname} ($onionAddress)");
      sb.writeln("Exported on ${DateTime.now()}");
      sb.writeln("-" * 50);
      sb.writeln("");
      
      // Export oldest first
      for (final msg in messages.reversed) {
        final time = DateTime.fromMillisecondsSinceEpoch(msg.timestamp * 1000);
        final sender = msg.isSent ? "Me" : contact.nickname;
        sb.writeln("[$time] $sender: ${msg.text}");
      }
      
      final file = File('${downloadDir.path}/chat_export_${contact.nickname.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}.txt');
      await file.writeAsString(sb.toString());
      
      debugPrint("Chat exported to ${file.path}");
    } catch (e) {
      debugPrint("Error exporting chat: $e");
      rethrow;
    }
  }
  
  // Bulk Actions
  Future<void> clearAllChats() async {
    for (final contact in _contacts) {
      await clearChatMessages(contact.onionAddress);
    }
  }

  Future<void> archiveAllChats() async {
    final contactsToArchive = List<ContactInfo>.from(_contacts);
    for (final contact in contactsToArchive) {
      if (contact.onionAddress != 'web_messages_contact') {
        await archiveChat(contact.onionAddress);
      }
    }
  }

  Future<void> deleteAllChats() async {
    final contactsToDelete = List<ContactInfo>.from(_contacts);
    for (final contact in contactsToDelete) {
      if (contact.onionAddress != 'web_messages_contact') {
        await deleteChatWithMessages(contact.onionAddress);
      }
    }
  }
  int getUnreadCount(String onionAddress) => _unreadCounts[onionAddress] ?? 0;

  // Get last message text for a specific contact
  String getLastMessageText(String onionAddress) => _lastMessageTexts[onionAddress] ?? '';
  
  // Check if currently viewing web messages
  bool get isViewingWebMessages => _selectedContact?.onionAddress == 'web_messages_contact';

  // Check if a contact is "saved" (has a nickname that is different from their onion address)
  bool isSavedContact(ContactInfo contact) {
    if (contact.onionAddress == 'web_messages_contact') return true;
    final nick = contact.nickname.trim().toLowerCase();
    final address = contact.onionAddress.trim().toLowerCase();
    return nick != address && nick.isNotEmpty;
  }

  // Check if a contact has any message history
  bool hasMessages(String onionAddress) {
    return (_lastMessageTexts[onionAddress]?.isNotEmpty ?? false) || 
           (_lastMessageCounts[onionAddress] ?? 0) > 0;
  }

  void startPolling() {
    _pollTimer?.cancel();
    _contactRefreshTimer?.cancel();
    
    // Fast polling for messages AND new contacts (every 2 seconds)
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _checkAllChatsAndContacts();
    });
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _contactRefreshTimer?.cancel();
    _contactRefreshTimer = null;
  }
  
  // Combined check for new messages AND new contacts in one call
  Future<void> _checkAllChatsAndContacts() async {
    if (_isUpdating) return;
    
    try {
      _isUpdating = true;
      
      // FIRST: Check for new contacts (this is fast and critical for UX)
      bool hasNewContacts = false;
      try {
        final rawContacts = await getContacts();
        if (rawContacts.length != _lastKnownContactCount) {
          _lastKnownContactCount = rawContacts.length;
          
          final newContacts = rawContacts.map((c) => ContactInfo(
            onionAddress: c.onionAddress,
            nickname: _sanitizeText(c.nickname),
            lastSeen: c.lastSeen,
          )).toList();
          
          // Find new contacts
          final existingAddresses = _contacts.map((c) => c.onionAddress).toSet();
          String? newContactAddress;
          
          for (final contact in newContacts) {
            if (!existingAddresses.contains(contact.onionAddress)) {
              hasNewContacts = true;
              newContactAddress = contact.onionAddress;
              debugPrint('[ChatProvider] New contact detected: ${contact.onionAddress}');
            }
          }
          
          if (hasNewContacts) {
            _contacts = newContacts;
            // Immediately notify to show new contact in UI
            notifyListeners();
            
            // Load preview for new contact
            if (newContactAddress != null) {
              await _loadPreviewForContact(newContactAddress);
              
              // Show notification
              if (_notificationsEnabled) {
                final preview = _lastMessageTexts[newContactAddress] ?? 'New message';
                _showNotification('New message', preview);
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[ChatProvider] Error checking contacts: $e');
      }
      
      // Check web messages
      try {
        final pendingCount = await getWebMessageCount();
        if (pendingCount != _webMessageCount) {
          _webMessageCount = pendingCount;
          notifyListeners();
        }
      } catch (_) {}
      
      bool hasAnyNewMessages = false;
      
      // Check each contact for new messages
      for (final contact in _contacts) {
        if (contact.onionAddress == 'web_messages_contact') continue;
        if (_blockedContacts.contains(contact.onionAddress)) continue;
        
        try {
          final messages = await getMessages(contactOnion: contact.onionAddress, limit: 10);
          if (messages.isEmpty) continue;
          
          // Get last known count for this contact
          final lastKnownCount = _lastMessageCounts[contact.onionAddress] ?? 0;
          final receivedMessages = messages.where((m) => !m.isSent).toList();
          final currentReceivedCount = receivedMessages.length;
          
          // Check if there are new received messages
          if (currentReceivedCount > lastKnownCount) {
            final newMessageCount = currentReceivedCount - lastKnownCount;
            
            // Update unread count (add new messages to existing unread)
            final currentUnread = _unreadCounts[contact.onionAddress] ?? 0;
            _unreadCounts[contact.onionAddress] = currentUnread + newMessageCount;
            
            // Update last known count
            _lastMessageCounts[contact.onionAddress] = currentReceivedCount;
            
            hasAnyNewMessages = true;
            
            // Show notification if:
            // 1. This contact is NOT currently selected, OR
            // 2. The app window is not focused
            final isSelected = _selectedContact?.onionAddress == contact.onionAddress;
            final isFocused = await windowManager.isFocused();
            final isMuted = _mutedContacts.contains(contact.onionAddress);
            
            if ((!isSelected || !isFocused) && _notificationsEnabled && !isMuted) {
              final lastMsg = receivedMessages.first;
              String previewText;
              
              if (lastMsg.msgType == 'audio') {
                previewText = '🎤 Audio Message';
              } else if (lastMsg.msgType == 'image') {
                previewText = '📷 Image';
              } else if (lastMsg.msgType == 'file') {
                previewText = '📁 File';
              } else {
                previewText = _sanitizeText(lastMsg.text);
              }
              
              final nickname = contact.nickname.isNotEmpty ? contact.nickname : 'Unknown';
              _showNotification('New message from $nickname', previewText);
            }
          }
          
          // Update last message text for preview (regardless of new messages)
          if (messages.isNotEmpty) {
            final lastMsg = messages.first;
            String previewText;
            
            if (lastMsg.msgType == 'audio') {
              previewText = '🎤 Audio Message';
            } else if (lastMsg.msgType == 'image') {
              previewText = '📷 Image';
            } else if (lastMsg.msgType == 'file') {
              previewText = '📁 File';
            } else {
              previewText = _sanitizeText(lastMsg.text);
            }
            
            _lastMessageTexts[contact.onionAddress] = previewText;
          }
        } catch (e) {
          // Ignore errors for individual contacts
        }
      }
      
      // Also update selected chat messages if any
      if (_selectedContact != null && 
          _selectedContact!.onionAddress != 'web_messages_contact' &&
          !_blockedContacts.contains(_selectedContact!.onionAddress)) {
        await loadMessages(silent: true);
      }
      
      if (hasAnyNewMessages) {
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error checking for new messages: $e');
    } finally {
      _isUpdating = false;
    }
  }
  
  // Load message preview for a specific contact
  Future<void> _loadPreviewForContact(String onionAddress) async {
    try {
      final messages = await getMessages(contactOnion: onionAddress, limit: 1);
      if (messages.isNotEmpty) {
        final lastMsg = messages.first;
        String previewText;
        
        if (lastMsg.msgType == 'audio') {
          previewText = '🎤 Audio Message';
        } else if (lastMsg.msgType == 'image') {
          previewText = '📷 Image';
        } else if (lastMsg.msgType == 'file') {
          previewText = '📁 File';
        } else {
          previewText = _sanitizeText(lastMsg.text);
        }
        
        _lastMessageTexts[onionAddress] = previewText;
        _lastMessageCounts[onionAddress] = 1;
        _unreadCounts[onionAddress] = (_unreadCounts[onionAddress] ?? 0) + 1;
      }
    } catch (_) {}
  }

  void _showNotification(String title, String body) {
    // Sanitize both title and body for display to prevent UTF-16 errors
    final cleanTitle = _sanitizeText(title);
    final cleanBody = _sanitizeText(body);
    
    final notification = LocalNotification(
      title: cleanTitle,
      body: cleanBody,
      silent: !_soundEnabled, // Use global sound setting
    );
    debugPrint('[ChatProvider] Showing notification (Silent: ${!_soundEnabled})');
    
    notification.show();
  }

  Future<void> loadContacts() async {
    // Only set loading to true if we don't have contacts yet to avoid flickering on refresh
    final isInitialLoad = _contacts.isEmpty;
    if (isInitialLoad) {
       _isLoading = true;
       notifyListeners();
    }
    
    try {
      final rawContacts = await getContacts();
      
      // Track contact count for new contact detection
      _lastKnownContactCount = rawContacts.length;
      
      // Sanitize contact nicknames to prevent UTF-16 errors
      _contacts = rawContacts.map((c) => ContactInfo(
        onionAddress: c.onionAddress,
        nickname: _sanitizeText(c.nickname),
        lastSeen: c.lastSeen,
      )).toList();
      
      // Refresh selectedContact with updated data (e.g., after nickname change)
      if (_selectedContact != null) {
        final updatedContact = _contacts.where(
          (c) => c.onionAddress == _selectedContact!.onionAddress
        ).firstOrNull;
        if (updatedContact != null) {
          _selectedContact = updatedContact;
        }
      }
      
      _isLoading = false;
      notifyListeners();
      
      // Load message previews in background after contacts are shown (only on initial load)
      if (isInitialLoad) {
        _loadMessagePreviewsAsync();
      }
    } catch (e) {
      debugPrint('Error loading contacts: $e');
      _isLoading = false;
      notifyListeners();
    }
  }
  
  // Load message previews asynchronously in background
  Future<void> _loadMessagePreviewsAsync() async {
    for (final contact in _contacts) {
      if (contact.onionAddress == 'web_messages_contact') continue;
      if (_blockedContacts.contains(contact.onionAddress)) continue;
      
      try {
        final messages = await getMessages(contactOnion: contact.onionAddress, limit: 1);
        if (messages.isNotEmpty) {
          final lastMsg = messages.first;
          String previewText;
          
          if (lastMsg.msgType == 'audio') {
            previewText = '🎤 Audio Message';
          } else if (lastMsg.msgType == 'image') {
            previewText = '📷 Image';
          } else if (lastMsg.msgType == 'file') {
            previewText = '📁 File';
          } else {
            previewText = _sanitizeText(lastMsg.text);
          }
          
          _lastMessageTexts[contact.onionAddress] = previewText;
          
          // Initialize message counts
          final receivedCount = messages.where((m) => !m.isSent).length;
          if (!_lastMessageCounts.containsKey(contact.onionAddress)) {
            _lastMessageCounts[contact.onionAddress] = receivedCount;
          }
        }
      } catch (e) {
        // Ignore errors for individual contacts
      }
    }
    notifyListeners();
  }

  Future<void> addNewContact(String onionAddress, String nickname) async {
    try {
      await addContact(onionAddress: onionAddress, nickname: nickname);
      await loadContacts();
    } catch (e) {
      debugPrint('Error adding contact: $e');
      rethrow;
    }
  }

  Future<void> removeContact(String onionAddress) async {
    // Don't allow removing the web messages contact
    if (onionAddress == 'web_messages_contact') return;
    
    try {
      await deleteContact(onionAddress: onionAddress);
      await loadContacts();
      if (_selectedContact?.onionAddress == onionAddress) {
        _selectedContact = null;
        _messages = [];
      }
    } catch (e) {
      debugPrint('Error deleting contact: $e');
      rethrow;
    }
  }

  // Delete a chat completely (contact + all messages from database)
  Future<void> deleteChatWithMessages(String onionAddress) async {
    // Don't allow deleting the web messages contact
    if (onionAddress == 'web_messages_contact') return;
    
    try {
      // Use the new API function that deletes both contact and messages
      await deleteChat(onionAddress: onionAddress);
      await loadContacts();
      if (_selectedContact?.onionAddress == onionAddress) {
        _selectedContact = null;
        _messages = [];
      }
      notifyListeners();
    } catch (e) {
      debugPrint('Error deleting chat: $e');
      rethrow;
    }
  }

  // Clear all messages but keep the contact (deletes from database)
  Future<void> clearChatMessages(String onionAddress) async {
    try {
      // Use the new API function to delete all messages from database
      final deletedCount = await clearChat(onionAddress: onionAddress);
      debugPrint('Cleared $deletedCount messages for $onionAddress');
      
      // Clear local message caches so the contact disappears from sidebar (if filtering by activity)
      _lastMessageTexts.remove(onionAddress);
      _lastMessageCounts.remove(onionAddress);
      _unreadCounts.remove(onionAddress);

      // Clear local messages if selected
      if (_selectedContact?.onionAddress == onionAddress) {
        _messages = [];
      }
      
      notifyListeners();
    } catch (e) {
      debugPrint('Error clearing chat: $e');
      rethrow;
    }
  }

  // Delete a single message by ID
  Future<void> deleteMessage(String messageId) async {
    try {
      final result = await api.deleteMessage(messageId: messageId);
      debugPrint('Delete message $messageId result: $result');
      
      if (result) {
        // Remove from local messages list
        _messages.removeWhere((m) => m.id == messageId);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error deleting message: $e');
      rethrow;
    }
  }

  // Archive a chat (move to archived list)
  Future<void> archiveChat(String onionAddress) async {
    // Don't allow archiving the web messages contact
    if (onionAddress == 'web_messages_contact') return;
    
    try {
      // Find the contact and move to archived list
      final contactIndex = _contacts.indexWhere((c) => c.onionAddress == onionAddress);
      if (contactIndex != -1) {
        final contact = _contacts[contactIndex];
        _archivedContacts.add(contact);
        _contacts.removeAt(contactIndex);
        
        if (_selectedContact?.onionAddress == onionAddress) {
          _selectedContact = null;
          _messages = [];
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error archiving chat: $e');
      rethrow;
    }
  }

  // Unarchive a chat (move back to contacts list)
  Future<void> unarchiveChat(String onionAddress) async {
    try {
      final archivedIndex = _archivedContacts.indexWhere((c) => c.onionAddress == onionAddress);
      if (archivedIndex != -1) {
        final contact = _archivedContacts[archivedIndex];
        _contacts.add(contact);
        _archivedContacts.removeAt(archivedIndex);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error unarchiving chat: $e');
      rethrow;
    }
  }

  void selectContact(ContactInfo contact) {
    _selectedContact = contact;
    _showingContactInfo = false;  // Hide contact info when selecting a contact
    _showingMyProfile = false;    // Hide my profile when selecting a contact
    
    // Clear web message count if selecting web messages
    if (contact.onionAddress == 'web_messages_contact') {
      _webMessageCount = 0;
    }
    
    // Clear unread count for this contact
    _unreadCounts[contact.onionAddress] = 0;
    
    notifyListeners();
    loadMessages();
  }

  void showContactInfo() {
    _showingContactInfo = true;
    _showingMyProfile = false;
    notifyListeners();
  }

  void hideContactInfo() {
    _showingContactInfo = false;
    notifyListeners();
  }

  void showMyProfile() {
    _showingMyProfile = true;
    _showingContactInfo = false;
    notifyListeners();
  }

  void hideMyProfile() {
    _showingMyProfile = false;
    notifyListeners();
  }

  void clearSelection() {
    _selectedContact = null;
    _messages = [];
    _showingContactInfo = false;
    _showingMyProfile = false;
    notifyListeners();
  }

  Future<void> loadMessages({bool silent = false}) async {
    if (_selectedContact == null) {
      return;
    }
    
    try {
      final rawMessages = await getMessages(
        contactOnion: _selectedContact!.onionAddress,
        limit: 100,
      );
      
      if (!silent) {
        debugPrint('[ChatProvider] loadMessages: Got ${rawMessages.length} messages');
      }
      
      // Quick check: if message count is same and last message ID is same, skip update
      if (silent && rawMessages.isNotEmpty && _messages.isNotEmpty) {
        if (rawMessages.length == _messages.length && rawMessages.first.id == _messages.last.id) {
          // No new messages, skip update
          return;
        }
      }
      
      // Sanitize message text to fix UTF-16 encoding issues
      final newMessages = rawMessages.map((msg) {
        // Only sanitize text messages. Media messages contain base64 data which must be preserved exactly.
        final isMedia = msg.msgType == 'image' || msg.msgType == 'audio' || msg.msgType == 'file';
        final sanitizedText = isMedia ? msg.text : _sanitizeText(msg.text);
        return MessageInfo(
          id: msg.id,
          text: sanitizedText,
          senderId: msg.senderId,
          recipientId: msg.recipientId,
          timestamp: msg.timestamp,
          isSent: msg.isSent,
          isRead: msg.isRead,
          msgType: msg.msgType,
        );
      }).where((msg) {
        // If blocked, hide messages received AFTER the block time
        if (_blockedContacts.contains(_selectedContact!.onionAddress)) {
           final blockedTime = _blockedSince[_selectedContact!.onionAddress];
           if (blockedTime != null && !msg.isSent && msg.timestamp > blockedTime) {
             return false;
           }
        }
        return true;
      }).toList();
      
      // Reverse to show oldest first
      final reversedMessages = newMessages.reversed.toList();
      
      // Update last message text for preview
      if (_selectedContact != null && newMessages.isNotEmpty) {
        final receivedCount = reversedMessages.where((m) => !m.isSent).length;
        _lastMessageCounts[_selectedContact!.onionAddress] = receivedCount;
        
        final lastMsg = newMessages.first;
        String previewText;
        
        if (lastMsg.msgType == 'audio') {
          previewText = '🎤 Audio Message';
        } else if (lastMsg.msgType == 'image') {
          previewText = '📷 Image';
        } else if (lastMsg.msgType == 'file') {
          previewText = '📁 File';
        } else {
          previewText = lastMsg.text;
        }
        
        _lastMessageTexts[_selectedContact!.onionAddress] = previewText;
      }
      
      // Only notify if messages actually changed
      final hasNewMessages = _messages.length != reversedMessages.length || 
          (_messages.isNotEmpty && reversedMessages.isNotEmpty && _messages.last.id != reversedMessages.last.id);
      
      if (hasNewMessages) {
        _messages = reversedMessages;
        notifyListeners();
      }
    } catch (e) {
      if (!silent) {
        debugPrint('[ChatProvider] Error loading messages: $e');
      }
    }
  }

  // Sanitize text to handle malformed UTF-16 characters
  // This is critical to prevent Flutter rendering crashes
  String _sanitizeText(String text) {
    if (text.isEmpty) return text;
    try {
      // Replace URL-encoded plus signs with spaces
      String cleaned = text.replaceAll('+', ' ');
      // Remove any invalid UTF-16 surrogate pairs
      final buffer = StringBuffer();
      for (int i = 0; i < cleaned.length; i++) {
        final codeUnit = cleaned.codeUnitAt(i);
        if (codeUnit >= 0x0000 && codeUnit <= 0xD7FF) {
          buffer.writeCharCode(codeUnit);
        } else if (codeUnit >= 0xE000 && codeUnit <= 0xFFFF) {
          buffer.writeCharCode(codeUnit);
        } else if (codeUnit >= 0xD800 && codeUnit <= 0xDBFF && i + 1 < cleaned.length) {
          final nextCodeUnit = cleaned.codeUnitAt(i + 1);
          if (nextCodeUnit >= 0xDC00 && nextCodeUnit <= 0xDFFF) {
            buffer.writeCharCode(codeUnit);
            buffer.writeCharCode(nextCodeUnit);
            i++;
          }
        }
        // Skip invalid surrogate pairs silently
      }
      final result = buffer.toString();
      return result.isEmpty ? ' ' : result; // Return space instead of empty to avoid rendering issues
    } catch (e) {
      // If all else fails, return ASCII-only version
      return text.replaceAll(RegExp(r'[^\x00-\x7F]'), '?');
    }
  }

  Future<void> sendNewMessage(String text) async {
    if (_selectedContact == null || text.isEmpty) {
      debugPrint('[ChatProvider] sendNewMessage: No contact selected or empty text');
      return;
    }
    
    // Can't send messages to web messages contact (it's receive only)
    if (isViewingWebMessages) {
      debugPrint('[ChatProvider] Cannot send messages to web contact');
      return;
    }
    
    debugPrint('[ChatProvider] Sending message to: ${_selectedContact!.onionAddress}');
    debugPrint('[ChatProvider] Message text: $text');
    
    try {
      final result = await sendMessage(
        onionAddress: _selectedContact!.onionAddress,
        message: text,
      );
      debugPrint('[ChatProvider] Send result: $result');
      await loadMessages();
    } catch (e) {
      debugPrint('[ChatProvider] Error sending message: $e');
      rethrow;
    }
  }

  Future<void> sendFileMedia(File file, String type) async {
    if (_selectedContact == null) return;
    if (isViewingWebMessages) return;

    debugPrint('[ChatProvider] Sending $type: ${file.path}');

    try {
      await sendFile(
        onionAddress: _selectedContact!.onionAddress,
        filePath: file.path,
        fileType: type,
      );
      await loadMessages();
    } catch (e) {
      debugPrint('[ChatProvider] Error sending file: $e');
      rethrow;
    }
  }
  
  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }
}
