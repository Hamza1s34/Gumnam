import 'dart:async';
import 'package:flutter/material.dart';
import 'package:tor_messenger_ui/generated/rust_bridge/api.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:window_manager/window_manager.dart';

class ChatProvider extends ChangeNotifier {
  List<ContactInfo> _contacts = [];
  List<ContactInfo> _archivedContacts = [];
  List<MessageInfo> _messages = [];
  ContactInfo? _selectedContact;
  bool _isLoading = false;
  int _webMessageCount = 0;
  Timer? _pollTimer;
  bool _showingContactInfo = false;
  bool _showingMyProfile = false;
  final Map<String, int> _unreadCounts = {};  // Track unread messages per contact
  final Map<String, int> _lastMessageCounts = {};  // Track last known received message counts
  final Map<String, String> _lastMessageTexts = {}; // Track last message text for preview

  List<ContactInfo> get contacts => _contacts;
  List<ContactInfo> get archivedContacts => _archivedContacts;
  List<MessageInfo> get messages => _messages;
  ContactInfo? get selectedContact => _selectedContact;
  bool get isLoading => _isLoading;
  int get webMessageCount => _webMessageCount;
  bool get showingContactInfo => _showingContactInfo;
  bool get showingMyProfile => _showingMyProfile;
  
  // Get unread count for a specific contact
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
    // Check if we have tracked texts or just rely on the count from backend
    // Since we don't always load texts, the LastMessageCounts is reliable for received
    // For sent messages, we might need to rely on the loaded _messages list if selected,
    // but globally we rely on the backend count if mapped.
    // However, currently we only track _lastMessageCounts (received) and _lastMessageTexts (last preview).
    // A robust way: if we have a last message text, we have messages.
    return (_lastMessageTexts[onionAddress]?.isNotEmpty ?? false) || 
           (_lastMessageCounts[onionAddress] ?? 0) > 0;
  }

  void startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _checkForNewMessages();
    });
  }

  void stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _checkForNewMessages() async {
    try {
      // Check for pending web messages
      final pendingCount = await getWebMessageCount();
      if (pendingCount > 0) {
        _webMessageCount = pendingCount;
        notifyListeners();
      }
      
      // Check if there are new incoming messages using the backend counter
      // This detects messages from unknown senders who got auto-added as contacts
      final newMessageCount = await getNewMessageCount();
      if (newMessageCount > 0) {
        debugPrint('[ChatProvider] Detected $newMessageCount new messages, reloading contacts');
        // Reload contacts to pick up any new contacts auto-added by the backend
        await loadContacts();
      }
      
      // Check each contact for new messages
      bool hasNewMessages = false;
      bool shouldNotify = false;
      String? notificationTitle;
      String? notificationBody;

      for (final contact in _contacts) {
        if (contact.onionAddress == 'web_messages_contact') continue;
        
        try {
          final messages = await getMessages(contactOnion: contact.onionAddress, limit: 100);
          final currentCount = _unreadCounts[contact.onionAddress] ?? 0;
          // Count received (not sent by us) messages
          final receivedCount = messages.where((m) => !m.isSent).length;
          // If there are more received messages than we've tracked, update
          final lastKnownCount = _lastMessageCounts[contact.onionAddress] ?? 0;
          
          if (receivedCount > lastKnownCount) {
            final newMessages = receivedCount - lastKnownCount;
            _unreadCounts[contact.onionAddress] = currentCount + newMessages;
            _lastMessageCounts[contact.onionAddress] = receivedCount;
            hasNewMessages = true;
            
            // Determine if we should notify:
            // 1. If this contact is NOT selected
            // 2. OR if the window is not focused (even if selected)
            final isSelected = _selectedContact?.onionAddress == contact.onionAddress;
            final isFocused = await windowManager.isFocused();
            
            if (!isSelected || !isFocused) {
               shouldNotify = true;
               notificationTitle = 'New Message from ${contact.nickname.isEmpty ? "Unknown" : contact.nickname}';
               notificationBody = messages.first.text; // messages is likely newest first due to API, check logic order
               // Logic check: getMessages returns limit 100. Usually sorted by DB. 
               // In loadMessages we reversed it. Here we take raw. Let's assume index 0 is newest.
            }
          }
          
          // Update last message text for preview (first message is newest)
          if (messages.isNotEmpty) {
             // Sanitize the text before storing
             _lastMessageTexts[contact.onionAddress] = _sanitizeText(messages.first.text);
          }
        } catch (e) {
          // Ignore errors for individual contacts
        }
      }
      
      if (hasNewMessages) {
        notifyListeners();
      }
      
      if (shouldNotify && notificationTitle != null) {
        _showNotification(notificationTitle, notificationBody ?? 'You have a new message');
      }
      
      // If a contact is selected, reload messages to check for new ones
      if (_selectedContact != null) {
        await loadMessages(silent: true);
      }
    } catch (e) {
      // Silently fail for polling errors to avoid log spam
    }
  }

  void _showNotification(String title, String body) {
    // Sanitize body for display
    final cleanBody = _sanitizeText(body);
    
    final notification = LocalNotification(
      title: title,
      body: cleanBody,
      silent: false, // This plays the default system sound
    );
    
    notification.show();
  }

  Future<void> loadContacts() async {
    _isLoading = true;
    notifyListeners();
    
    try {
      _contacts = await getContacts();
      
      // Refresh selectedContact with updated data (e.g., after nickname change)
      if (_selectedContact != null) {
        final updatedContact = _contacts.where(
          (c) => c.onionAddress == _selectedContact!.onionAddress
        ).firstOrNull;
        if (updatedContact != null) {
          _selectedContact = updatedContact;
        }
      }
    } catch (e) {
      debugPrint('Error loading contacts: $e');
    }
    
    _isLoading = false;
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
    
    if (!silent) {
      debugPrint('[ChatProvider] loadMessages: Loading for ${_selectedContact!.onionAddress}');
    }
    
    try {
      final rawMessages = await getMessages(
        contactOnion: _selectedContact!.onionAddress,
        limit: 100,
      );
      
      if (!silent) {
        debugPrint('[ChatProvider] loadMessages: Got ${rawMessages.length} messages');
      }
      
      // Sanitize message text to fix UTF-16 encoding issues
      final newMessages = rawMessages.map((msg) {
        final sanitizedText = _sanitizeText(msg.text);
        return MessageInfo(
          id: msg.id,
          text: sanitizedText,
          senderId: msg.senderId,
          recipientId: msg.recipientId,
          timestamp: msg.timestamp,
          isSent: msg.isSent,
          isRead: msg.isRead,
        );
      }).toList();
      
      // Reverse to show oldest first
      final reversedMessages = newMessages.reversed.toList();
      
      // Update last message count for this contact (for unread tracking)
      if (_selectedContact != null) {
        final receivedCount = reversedMessages.where((m) => !m.isSent).length;
        _lastMessageCounts[_selectedContact!.onionAddress] = receivedCount;
        
        // Update last message text for preview
        if (newMessages.isNotEmpty) {
           // newMessages is raw mapped (newest first? no wait.. code says reversedMessages is oldest first)
           // Raw fetch from getMessages (limit 100) usually returns newest first or based on DB query
           // looking at logic below: final reversedMessages = newMessages.reversed.toList();
           // which implies newMessages is Newest->Oldest. 
           // So first item of newMessages is the newest.
           _lastMessageTexts[_selectedContact!.onionAddress] = newMessages.first.text; 
        }
      }
      
      // Only notify if messages changed to avoid unnecessary rebuilds
      if (_messages.length != reversedMessages.length || 
          _messages.isNotEmpty && reversedMessages.isNotEmpty && _messages.last.id != reversedMessages.last.id) {
        _messages = reversedMessages;
        notifyListeners();
      } else {
        // If lengths are same, check if content changed (e.g. status update)
        _messages = reversedMessages;
        // Don't notify if nothing meaningful changed, but updating the list reference is good practice
      }
    } catch (e) {
      if (!silent) {
        debugPrint('[ChatProvider] Error loading messages: $e');
      }
    }
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
      }
      return buffer.toString();
    } catch (e) {
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
  
  @override
  void dispose() {
    stopPolling();
    super.dispose();
  }
}
