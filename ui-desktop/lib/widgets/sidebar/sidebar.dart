import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:tor_messenger_ui/services/tor_service_provider.dart';
import 'package:tor_messenger_ui/services/chat_provider.dart';
import 'package:tor_messenger_ui/theme/app_theme.dart';
import 'package:tor_messenger_ui/widgets/dialogs/new_chat_dialog.dart';
import 'package:tor_messenger_ui/widgets/dialogs/contact_info_dialog.dart';
import 'package:tor_messenger_ui/screens/settings_screen.dart';

class Sidebar extends StatefulWidget {
  const Sidebar({super.key});

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  final _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    // Contacts are already loaded in main.dart, no need to reload here
    // Only reload if contacts list is empty (rare edge case)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final chatProvider = context.read<ChatProvider>();
      if (chatProvider.contacts.isEmpty && !chatProvider.isLoading) {
        chatProvider.loadContacts();
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _showNewChatDialog() {
    showDialog(
      context: context,
      builder: (context) => const NewChatDialog(),
    );
  }

  // Sanitize text to handle malformed UTF-16 characters
  String _sanitizeText(String text) {
    if (text.isEmpty) return ' '; // Return space to prevent empty string rendering issues
    try {
      final buffer = StringBuffer();
      for (int i = 0; i < text.length; i++) {
        final codeUnit = text.codeUnitAt(i);
        if (codeUnit >= 0x0000 && codeUnit <= 0xD7FF) {
          buffer.writeCharCode(codeUnit);
        } else if (codeUnit >= 0xE000 && codeUnit <= 0xFFFF) {
          buffer.writeCharCode(codeUnit);
        } else if (codeUnit >= 0xD800 && codeUnit <= 0xDBFF && i + 1 < text.length) {
          final nextCodeUnit = text.codeUnitAt(i + 1);
          if (nextCodeUnit >= 0xDC00 && nextCodeUnit <= 0xDFFF) {
            buffer.writeCharCode(codeUnit);
            buffer.writeCharCode(nextCodeUnit);
            i++;
          }
        }
        // Skip invalid surrogate pairs silently
      }
      final result = buffer.toString();
      return result.isEmpty ? ' ' : result;
    } catch (e) {
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

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.sidebarBackground,
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(16),
            color: AppTheme.sidebarBackground,
            child: Row(
              children: [
                // Clickable profile avatar
                GestureDetector(
                  onTap: () => context.read<ChatProvider>().showMyProfile(),
                  child: Consumer<TorServiceProvider>(
                    builder: (context, tor, child) {
                      return Stack(
                        children: [
                          const CircleAvatar(
                            backgroundColor: AppTheme.primaryPurple,
                            child: Icon(Icons.person, color: Colors.white),
                          ),
                          // Online status indicator
                          Positioned(
                            right: 0,
                            bottom: 0,
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: tor.isReady ? Colors.green : Colors.orange,
                                shape: BoxShape.circle,
                                border: Border.all(color: AppTheme.sidebarBackground, width: 2),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.chat),
                  onPressed: _showNewChatDialog,
                  tooltip: 'New Chat',
                ),
                  IconButton(
                  icon: const Icon(Icons.more_vert),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const SettingsScreen()),
                    );
                  },
                  tooltip: 'Settings',
                ),
              ],
            ),
          ),
          // Search
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _searchController,
              onChanged: (value) {
                setState(() => _searchQuery = value.toLowerCase());
              },
              decoration: InputDecoration(
                hintText: 'Search contacts',
                prefixIcon: const Icon(Icons.search, color: AppTheme.textSecondary),
                filled: true,
                fillColor: AppTheme.receivedMessage,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          // Archived Chats Section
          Consumer<ChatProvider>(
            builder: (context, chatProvider, child) {
              if (chatProvider.archivedContacts.isEmpty) {
                return const SizedBox.shrink();
              }
              return ExpansionTile(
                leading: const Icon(Icons.archive, color: AppTheme.textSecondary),
                title: Text(
                  'Archived Chats (${chatProvider.archivedContacts.length})',
                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14),
                ),
                collapsedIconColor: AppTheme.textSecondary,
                iconColor: AppTheme.textSecondary,
                children: chatProvider.archivedContacts.map((contact) {
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundColor: Colors.grey.shade700,
                      child: Text(
                        _safeSubstring(contact.nickname, 0, 1).toUpperCase(),
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                    title: Text(
                      _sanitizeText(contact.nickname),
                      style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.unarchive, size: 18, color: AppTheme.textSecondary),
                      onPressed: () => chatProvider.unarchiveChat(contact.onionAddress),
                      tooltip: 'Unarchive',
                    ),
                    onTap: () => chatProvider.selectContact(contact),
                  );
                }).toList(),
              );
            },
          ),
          // Contact List
          Expanded(
            child: Consumer<ChatProvider>(
              builder: (context, chatProvider, child) {
                if (chatProvider.isLoading) {
                  return const Center(
                    child: CircularProgressIndicator(),
                  );
                }

                final contacts = chatProvider.contacts.where((c) {
                  // Search query filter
                  if (_searchQuery.isNotEmpty) {
                    return c.nickname.toLowerCase().contains(_searchQuery) ||
                        c.onionAddress.toLowerCase().contains(_searchQuery);
                  }
                  
                  // Filter out blocked contacts by default unless searched (REMOVED: User wants them to stay)
                  // if (chatProvider.isBlocked(c.onionAddress)) {
                  //   return false;
                  // }
                  
                  // Default view: Show only "active" chats
                  // 1. Saved contacts WITH messages
                  // 2. Any contact with unread messages
                  // 3. The currently selected contact
                  
                  final hasHistory = chatProvider.hasMessages(c.onionAddress);
                  final hasUnread = chatProvider.getUnreadCount(c.onionAddress) > 0;
                  final isSelected = chatProvider.selectedContact?.onionAddress == c.onionAddress;
                  final isWeb = c.onionAddress == 'web_messages_contact';
                  
                  // Always show web contact if it has messages
                  if (isWeb) return chatProvider.webMessageCount > 0 || isSelected;

                  return hasHistory || hasUnread || isSelected;
                }).toList();

                if (contacts.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.chat_bubble_outline,
                          size: 48,
                          color: AppTheme.textSecondary,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _searchQuery.isNotEmpty
                              ? 'No contacts found'
                              : 'No conversations yet',
                          style: const TextStyle(color: AppTheme.textSecondary),
                        ),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: _showNewChatDialog,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Start a new chat'),
                          style: TextButton.styleFrom(
                            foregroundColor: AppTheme.primaryPurple,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  itemCount: contacts.length,
                  itemBuilder: (context, index) {
                    final contact = contacts[index];
                    final isSelected = chatProvider.selectedContact?.onionAddress == contact.onionAddress;
                    final isWebContact = contact.onionAddress == 'web_messages_contact';
                    
                    return _ChatListTile(
                      contact: contact,
                      isSelected: isSelected,
                      isWebContact: isWebContact,
                      webMessageCount: chatProvider.webMessageCount,
                      unreadCount: chatProvider.getUnreadCount(contact.onionAddress),
                      lastMessage: chatProvider.getLastMessageText(contact.onionAddress),
                      onTap: () => chatProvider.selectContact(contact),
                      onLongPress: () {
                        if (!isWebContact) {
                          _showContactOptions(context, contact);
                        }
                      },
                      onDelete: isWebContact ? null : () => _confirmDeleteChat(context, contact),
                      onClear: () => _confirmClearChat(context, contact),
                      onArchive: isWebContact ? null : () => _confirmArchiveChat(context, contact),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _formatLastSeen(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0) {
      return DateFormat('h:mm a').format(date);
    } else if (diff.inDays == 1) {
      return 'Yesterday';
    } else if (diff.inDays < 7) {
      return DateFormat('EEE').format(date);
    } else {
      return DateFormat('MM/dd').format(date);
    }
  }

  void _showContactOptions(BuildContext context, contact) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.sidebarBackground,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.info_outline, color: AppTheme.primaryPurple),
              title: const Text('Contact Info', style: TextStyle(color: AppTheme.primaryPurple)),
              onTap: () {
                Navigator.pop(context);
                showDialog(
                  context: context,
                  builder: (context) => ContactInfoDialog(onionAddress: contact.onionAddress),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy Address'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: contact.onionAddress));
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Address copied!')),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.clear_all, color: Colors.orange),
              title: const Text('Clear Chat', style: TextStyle(color: Colors.orange)),
              onTap: () {
                Navigator.pop(context);
                _confirmClearChat(context, contact);
              },
            ),
            ListTile(
              leading: const Icon(Icons.archive, color: Colors.blue),
              title: const Text('Archive Chat', style: TextStyle(color: Colors.blue)),
              onTap: () {
                Navigator.pop(context);
                _confirmArchiveChat(context, contact);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('Delete Chat', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                _confirmDeleteChat(context, contact);
              },
            ),
            const Divider(),
             Consumer<ChatProvider>(
              builder: (context, chatProvider, _) {
                 final isBlocked = chatProvider.isBlocked(contact.onionAddress);
                 final isMuted = chatProvider.isMuted(contact.onionAddress);
                 return Column(
                  children: [
                    ListTile(
                      leading: Icon(isMuted ? Icons.notifications_off : Icons.notifications_active, color: AppTheme.textSecondary),
                      title: Text(isMuted ? 'Unmute' : 'Mute', style: const TextStyle(color: AppTheme.textPrimary)),
                      onTap: () {
                         if (isMuted) {
                           chatProvider.unmuteContact(contact.onionAddress);
                         } else {
                           chatProvider.muteContact(contact.onionAddress);
                         }
                         Navigator.pop(context);
                      },
                    ),
                    ListTile(
                      leading: Icon(isBlocked ? Icons.check_circle : Icons.block, color: isBlocked ? Colors.green : Colors.redAccent),
                      title: Text(isBlocked ? 'Unblock' : 'Block', style: TextStyle(color: isBlocked ? Colors.green : Colors.redAccent)),
                      onTap: () {
                         if (isBlocked) {
                           chatProvider.unblockContact(contact.onionAddress);
                         } else {
                           chatProvider.blockContact(contact.onionAddress);
                         }
                         Navigator.pop(context);
                      },
                    ),
                  ],
                 );
              },
            ),
             ListTile(
              leading: const Icon(Icons.download, color: AppTheme.primaryPurple),
              title: const Text('Export Chat', style: TextStyle(color: AppTheme.primaryPurple)),
               onTap: () async {
                Navigator.pop(context);
                try {
                  await context.read<ChatProvider>().exportChat(contact.onionAddress);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Chat exported to Downloads')),
                    );
                  }
                } catch (e) {
                   if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Export failed: $e')),
                    );
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteChat(BuildContext context, contact) async {
    final chatProvider = context.read<ChatProvider>();
    final isSaved = chatProvider.isSavedContact(contact);
    final safeName = _sanitizeText(contact.nickname);
    
    // Always use "Delete Chat" terminology for this action
    const title = 'Delete Chat?';
    final content = isSaved
        ? 'This will clear all messages with $safeName and remove the chat from the sidebar. The contact will remain in your address book.'
        : 'Are you sure you want to delete the chat with $safeName? This will remove the contact and all messages.';
    const actionText = 'Delete';
    const actionColor = Colors.red;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.sidebarBackground,
        title: const Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: actionColor),
            child: const Text(actionText),
          ),
        ],
      ),
    );

    if (confirm == true && context.mounted) {
      if (isSaved) {
        // Clear messages (caches cleared in provider)
        await chatProvider.clearChatMessages(contact.onionAddress);
        // Deselect triggers "disappear" from sidebar since logic is (hasMessages || isSelected)
        if (chatProvider.selectedContact?.onionAddress == contact.onionAddress) {
          chatProvider.clearSelection();
        }
      } else {
        await chatProvider.deleteChatWithMessages(contact.onionAddress);
      }
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
    if (confirm == true && context.mounted) {
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
    if (confirm == true && context.mounted) {
      context.read<ChatProvider>().archiveChat(contact.onionAddress);
    }
  }
}

// Custom chat list tile widget with hover menu
class _ChatListTile extends StatefulWidget {
  final dynamic contact;
  final bool isSelected;
  final bool isWebContact;
  final int webMessageCount;
  final int unreadCount;
  final String lastMessage;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback? onDelete;
  final VoidCallback? onClear;
  final VoidCallback? onArchive;

  const _ChatListTile({
    required this.contact,
    required this.isSelected,
    required this.isWebContact,
    required this.webMessageCount,
    this.unreadCount = 0,
    this.lastMessage = '',
    required this.onTap,
    required this.onLongPress,
    this.onDelete,
    this.onClear,
    this.onArchive,
  });

  @override
  State<_ChatListTile> createState() => _ChatListTileState();
}

class _ChatListTileState extends State<_ChatListTile> {
  bool _isHovering = false;

  // Sanitize text to handle malformed UTF-16 characters - MUST be called on ALL text
  String _sanitizeText(String text) {
    if (text.isEmpty) return ' '; // Return space to prevent empty string issues
    try {
      // Replace URL-encoded plus signs with spaces
      String cleaned = text.replaceAll('+', ' ');
      // Remove any invalid characters for display
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
      return result.isEmpty ? ' ' : result;
    } catch (e) {
      return text.replaceAll(RegExp(r'[^\x00-\x7F]'), '?');
    }
  }

  String _safeFirstChar(String text) {
    final sanitized = _sanitizeText(text);
    if (sanitized.isEmpty) return '?';
    return sanitized[0];
  }

  String _safeSubstring(String text, int start, int end) {
    final sanitized = _sanitizeText(text);
    if (sanitized.isEmpty) return '?';
    final actualStart = start >= sanitized.length ? 0 : start;
    final actualEnd = end > sanitized.length ? sanitized.length : end;
    if (actualStart >= actualEnd) return '';
    return sanitized.substring(actualStart, actualEnd);
  }

  String _formatLastSeen(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0) {
      return DateFormat('h:mm a').format(date);
    } else if (diff.inDays == 1) {
      return 'Yesterday';
    } else if (diff.inDays < 7) {
      return DateFormat('EEE').format(date);
    } else {
      return DateFormat('MM/dd').format(date);
    }
  }

  void _showMenu(BuildContext context) {
    final RenderBox button = context.findRenderObject() as RenderBox;
    final RenderBox overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(button.size.topRight(Offset.zero), ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );

    final chatProvider = context.read<ChatProvider>();
    final isMuted = chatProvider.isMuted(widget.contact.onionAddress);
    final isBlocked = chatProvider.isBlocked(widget.contact.onionAddress);

    showMenu<String>(
      context: context,
      position: position,
      color: AppTheme.sidebarBackground,
      items: [
        if (widget.onClear != null)
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
        if (widget.onArchive != null)
          const PopupMenuItem<String>(
            value: 'archive',
            child: Row(
              children: [
                Icon(Icons.archive, color: Colors.blue, size: 20),
                SizedBox(width: 12),
                Text('Archive', style: TextStyle(color: Colors.blue)),
              ],
            ),
          ),
        if (widget.onDelete != null)
          const PopupMenuItem<String>(
            value: 'delete',
            child: Row(
              children: [
                Icon(Icons.delete, color: Colors.red, size: 20),
                SizedBox(width: 12),
                Text('Delete', style: TextStyle(color: Colors.red)),
              ],
            ),
          ),
        const PopupMenuDivider(),
        if (!widget.isWebContact) ...[
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
        ],
      ],
    ).then((value) async {
       if (value == null) return;
       
       switch (value) {
         case 'clear':
           widget.onClear?.call();
           break;
         case 'archive':
           widget.onArchive?.call();
           break;
         case 'delete':
           widget.onDelete?.call();
           break;
         case 'mute':
           if (isMuted) {
             await chatProvider.unmuteContact(widget.contact.onionAddress);
           } else {
             await chatProvider.muteContact(widget.contact.onionAddress);
           }
           break;
         case 'block':
           if (isBlocked) {
             await chatProvider.unblockContact(widget.contact.onionAddress);
           } else {
             await chatProvider.blockContact(widget.contact.onionAddress);
           }
           break;
         case 'export':
           try {
              await chatProvider.exportChat(widget.contact.onionAddress);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Chat exported to Downloads')),
                );
              }
            } catch (e) {
               if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Export failed: $e')),
                );
              }
            }
            break;
       }
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasUnread = widget.unreadCount > 0 || (widget.isWebContact && widget.webMessageCount > 0);
    
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: Container(
        // Add subtle highlight for unread chats
        decoration: hasUnread && !widget.isSelected
            ? BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: AppTheme.primaryPurple,
                    width: 3,
                  ),
                ),
                color: AppTheme.primaryPurple.withOpacity(0.1),
              )
            : null,
        child: ListTile(
          selected: widget.isSelected,
          selectedTileColor: Colors.white.withOpacity(0.1),
          leading: Stack(
            children: [
              CircleAvatar(
                backgroundColor: widget.isWebContact 
                    ? Colors.blue 
                    : (widget.isSelected ? AppTheme.primaryPurple : (hasUnread ? AppTheme.primaryPurple : Colors.grey.shade700)),
                child: widget.isWebContact
                    ? const Icon(Icons.public, color: Colors.white)
                    : Text(
                        _safeFirstChar(widget.contact.nickname).toUpperCase(),
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
              ),
              // Web message count badge
              if (widget.isWebContact && widget.webMessageCount > 0)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '${widget.webMessageCount}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              // Regular contact unread count badge
              if (!widget.isWebContact && widget.unreadCount > 0)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                    decoration: const BoxDecoration(
                      color: AppTheme.primaryPurple,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      widget.unreadCount > 99 ? '99+' : '${widget.unreadCount}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
        title: Text(
          widget.contact.nickname == widget.contact.onionAddress
              ? '${_safeSubstring(widget.contact.onionAddress, 0, 12)}...${_safeSubstring(widget.contact.onionAddress, 50, widget.contact.onionAddress.length)}'
              : _sanitizeText(widget.contact.nickname),
          style: TextStyle(
            fontWeight: (widget.isSelected || widget.unreadCount > 0) ? FontWeight.bold : FontWeight.normal,
            color: widget.unreadCount > 0 ? Colors.white : AppTheme.textPrimary,
          ),
        ),
        subtitle: Text(
          widget.isWebContact 
              ? 'Messages from web visitors'
              : (widget.lastMessage.isNotEmpty 
                  ? _sanitizeText(widget.lastMessage)
                  : (widget.contact.onionAddress.length > 20 
                      ? '${_safeSubstring(widget.contact.onionAddress, 0, 20)}...'
                      : _sanitizeText(widget.contact.onionAddress))),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: widget.unreadCount > 0 ? AppTheme.textPrimary : AppTheme.textSecondary,
            fontWeight: widget.unreadCount > 0 ? FontWeight.bold : FontWeight.normal,
            fontSize: 12,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Show unread count in trailing if there are unread messages
            if (widget.unreadCount > 0 && !_isHovering)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.primaryPurple,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  widget.unreadCount > 99 ? '99+' : '${widget.unreadCount}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              )
            else if (widget.contact.lastSeen != null && !_isHovering)
              Text(
                _formatLastSeen(widget.contact.lastSeen!),
                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
              ),
            if (_isHovering && (widget.onDelete != null || widget.onClear != null || widget.onArchive != null))
              IconButton(
                icon: const Icon(Icons.more_vert, size: 18),
                onPressed: () => _showMenu(context),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                color: AppTheme.textSecondary,
              ),
          ],
        ),
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        hoverColor: Colors.white.withOpacity(0.05),
        ),
      ),
    );
  }
}
