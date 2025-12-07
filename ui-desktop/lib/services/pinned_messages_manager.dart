import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

/// Manages pinned messages state
class PinnedMessagesManager {
  static final PinnedMessagesManager _instance = PinnedMessagesManager._internal();
  factory PinnedMessagesManager() => _instance;
  PinnedMessagesManager._internal();

  // Map of contact onion address -> Set of pinned message IDs
  final Map<String, Set<String>> _pinnedMessages = {};
  bool _isLoaded = false;

  /// Load pinned messages from storage
  Future<void> load() async {
    if (_isLoaded) return;
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getString('pinned_messages');
      if (data != null) {
        final Map<String, dynamic> decoded = jsonDecode(data);
        decoded.forEach((key, value) {
          _pinnedMessages[key] = Set<String>.from(value as List);
        });
      }
      _isLoaded = true;
    } catch (e) {
      debugPrint('Error loading pinned messages: $e');
    }
  }

  /// Save pinned messages to storage
  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final Map<String, List<String>> toSave = {};
      _pinnedMessages.forEach((key, value) {
        toSave[key] = value.toList();
      });
      await prefs.setString('pinned_messages', jsonEncode(toSave));
    } catch (e) {
      debugPrint('Error saving pinned messages: $e');
    }
  }

  /// Check if a message is pinned
  bool isPinned(String contactAddress, String messageId) {
    return _pinnedMessages[contactAddress]?.contains(messageId) ?? false;
  }

  /// Toggle pin status for a message
  Future<void> togglePin(String contactAddress, String messageId) async {
    _pinnedMessages[contactAddress] ??= {};
    
    if (_pinnedMessages[contactAddress]!.contains(messageId)) {
      _pinnedMessages[contactAddress]!.remove(messageId);
    } else {
      _pinnedMessages[contactAddress]!.add(messageId);
    }
    
    await _save();
  }

  /// Pin a message
  Future<void> pin(String contactAddress, String messageId) async {
    _pinnedMessages[contactAddress] ??= {};
    _pinnedMessages[contactAddress]!.add(messageId);
    await _save();
  }

  /// Unpin a message
  Future<void> unpin(String contactAddress, String messageId) async {
    _pinnedMessages[contactAddress]?.remove(messageId);
    await _save();
  }

  /// Get all pinned message IDs for a contact
  Set<String> getPinnedMessageIds(String contactAddress) {
    return _pinnedMessages[contactAddress] ?? {};
  }

  /// Get count of pinned messages for a contact
  int getPinnedCount(String contactAddress) {
    return _pinnedMessages[contactAddress]?.length ?? 0;
  }

  /// Clear all pinned messages for a contact
  Future<void> clearPinnedForContact(String contactAddress) async {
    _pinnedMessages.remove(contactAddress);
    await _save();
  }
}
