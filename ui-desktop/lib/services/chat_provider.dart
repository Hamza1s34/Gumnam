import 'dart:async';
import 'package:flutter/material.dart';
import 'package:tor_messenger_ui/generated/rust_bridge/api.dart';

class ChatProvider extends ChangeNotifier {
  List<ContactInfo> _contacts = [];
  List<ContactInfo> _archivedContacts = [];
  List<MessageInfo> _messages = [];
  ContactInfo? _selectedContact;
  bool _isLoading = false;
  int _webMessageCount = 0;
  Timer? _pollTimer;

  List<ContactInfo> get contacts => _contacts;
  List<ContactInfo> get archivedContacts => _archivedContacts;
  List<MessageInfo> get messages => _messages;
  ContactInfo? get selectedContact => _selectedContact;
  bool get isLoading => _isLoading;
  int get webMessageCount => _webMessageCount;
  
  // Check if currently viewing web messages
  bool get isViewingWebMessages => _selectedContact?.onionAddress == 'web_messages_contact';

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
      
      // If a contact is selected, reload messages to check for new ones
      if (_selectedContact != null) {
        await loadMessages(silent: true);
      }
    } catch (e) {
      // Silently fail for polling errors to avoid log spam
    }
  }

  Future<void> loadContacts() async {
    _isLoading = true;
    notifyListeners();
    
    try {
      _contacts = await getContacts();
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
      
      // Clear local messages
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
    
    // Clear web message count if selecting web messages
    if (contact.onionAddress == 'web_messages_contact') {
      _webMessageCount = 0;
    }
    
    notifyListeners();
    loadMessages();
  }

  void clearSelection() {
    _selectedContact = null;
    _messages = [];
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
