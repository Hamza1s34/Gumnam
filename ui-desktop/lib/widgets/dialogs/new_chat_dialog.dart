import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tor_messenger_ui/services/chat_provider.dart';
import 'package:tor_messenger_ui/theme/app_theme.dart';

class NewChatDialog extends StatefulWidget {
  const NewChatDialog({super.key});

  @override
  State<NewChatDialog> createState() => _NewChatDialogState();
}

class _NewChatDialogState extends State<NewChatDialog> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _addressController = TextEditingController();
  final _nicknameController = TextEditingController();
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _addressController.dispose();
    _nicknameController.dispose();
    super.dispose();
  }

  // Sanitize text to handle malformed UTF-16 characters
  String _sanitizeText(String text) {
    if (text.isEmpty) return text;
    try {
      final buffer = StringBuffer();
      for (int i = 0; i < text.length; i++) {
        final codeUnit = text.codeUnitAt(i);
        // Basic Multilingual Plane (valid single code unit)
        if (codeUnit >= 0x0000 && codeUnit <= 0xD7FF) {
          buffer.writeCharCode(codeUnit);
        } else if (codeUnit >= 0xE000 && codeUnit <= 0xFFFF) {
          buffer.writeCharCode(codeUnit);
        } else if (codeUnit >= 0xD800 && codeUnit <= 0xDBFF && i + 1 < text.length) {
          // High surrogate - check for valid low surrogate
          final nextCodeUnit = text.codeUnitAt(i + 1);
          if (nextCodeUnit >= 0xDC00 && nextCodeUnit <= 0xDFFF) {
            buffer.writeCharCode(codeUnit);
            buffer.writeCharCode(nextCodeUnit);
            i++; // Skip next character (low surrogate)
          }
        }
        // Skip invalid surrogates silently
      }
      return buffer.toString().isEmpty ? '?' : buffer.toString();
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

  Future<void> _addContact() async {
    if (_addressController.text.isEmpty) {
      setState(() => _error = 'Please enter an onion address');
      return;
    }
    
    if (!_addressController.text.endsWith('.onion')) {
      setState(() => _error = 'Invalid onion address format');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final chatProvider = context.read<ChatProvider>();
      // Use full address as nickname if empty to mark as "unsaved"
      final nickname = _nicknameController.text.isEmpty 
          ? _addressController.text
          : _nicknameController.text;
      
      await chatProvider.addNewContact(_addressController.text, nickname);
      
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.sidebarBackground,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        width: 400,
        padding: const EdgeInsets.all(0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.primaryPurple.withOpacity(0.2),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.chat_bubble_outline, color: AppTheme.primaryPurple),
                  const SizedBox(width: 12),
                  const Text(
                    'New Chat',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            
            // Tabs
            TabBar(
              controller: _tabController,
              tabs: const [
                Tab(text: 'Contacts'),
                Tab(text: 'New Contact'),
              ],
              indicatorColor: AppTheme.primaryPurple,
              labelColor: AppTheme.primaryPurple,
              unselectedLabelColor: AppTheme.textSecondary,
            ),
            
            // Tab content
            SizedBox(
              height: 300,
              child: TabBarView(
                controller: _tabController,
                children: [
                  // Existing contacts
                  _buildContactsList(),
                  
                  // Add new contact
                  _buildAddContactForm(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContactsList() {
    return Consumer<ChatProvider>(
      builder: (context, chatProvider, child) {
        // Filter: only show "saved" contacts (where nickname != onion address)
        final contacts = chatProvider.contacts.where((c) => chatProvider.isSavedContact(c)).toList();

        if (contacts.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.people_outline, size: 48, color: AppTheme.textSecondary),
                SizedBox(height: 16),
                Text(
                  'No saved contacts',
                  style: TextStyle(color: AppTheme.textSecondary),
                ),
                SizedBox(height: 8),
                Text(
                  'Add a new contact to start chatting',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
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
                style: const TextStyle(color: AppTheme.textPrimary),
              ),
              subtitle: Text(
                '${_safeSubstring(contact.onionAddress, 0, 16)}...',
                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, size: 20, color: Colors.grey),
                onPressed: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      backgroundColor: AppTheme.sidebarBackground,
                      title: const Text('Remove Contact?'),
                      content: Text('Remove ${contact.nickname} from your contacts? This will not delete chat history.'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          style: TextButton.styleFrom(foregroundColor: Colors.red),
                          child: const Text('Remove'),
                        ),
                      ],
                    ),
                  );
                  
                  if (confirm == true && context.mounted) {
                     await chatProvider.removeContact(contact.onionAddress);
                  }
                },
              ),
              onTap: () {
                chatProvider.selectContact(contact);
                Navigator.of(context).pop();
              },
              hoverColor: Colors.white.withOpacity(0.05),
            );
          },
        );
      },
    );
  }

  Widget _buildAddContactForm() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Onion Address *',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _addressController,
            decoration: InputDecoration(
              hintText: 'xxxxx.onion',
              filled: true,
              fillColor: AppTheme.receivedMessage,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              prefixIcon: const Icon(Icons.link, color: AppTheme.textSecondary),
            ),
            style: const TextStyle(color: AppTheme.textPrimary),
          ),
          const SizedBox(height: 16),
          const Text(
            'Nickname (optional)',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _nicknameController,
            decoration: InputDecoration(
              hintText: 'Contact name',
              filled: true,
              fillColor: AppTheme.receivedMessage,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              prefixIcon: const Icon(Icons.person, color: AppTheme.textSecondary),
            ),
            style: const TextStyle(color: AppTheme.textPrimary),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(color: Colors.red, fontSize: 12),
            ),
          ],
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _addContact,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryPurple,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: _isLoading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Add Contact', style: TextStyle(color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }
}
