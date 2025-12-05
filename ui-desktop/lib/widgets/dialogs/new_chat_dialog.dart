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
      final nickname = _nicknameController.text.isEmpty 
          ? _addressController.text.substring(0, 8)
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
        if (chatProvider.contacts.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.people_outline, size: 48, color: AppTheme.textSecondary),
                SizedBox(height: 16),
                Text(
                  'No contacts yet',
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
          itemCount: chatProvider.contacts.length,
          itemBuilder: (context, index) {
            final contact = chatProvider.contacts[index];
            return ListTile(
              leading: CircleAvatar(
                backgroundColor: AppTheme.primaryPurple,
                child: Text(
                  contact.nickname.substring(0, 1).toUpperCase(),
                  style: const TextStyle(color: Colors.white),
                ),
              ),
              title: Text(
                contact.nickname,
                style: const TextStyle(color: AppTheme.textPrimary),
              ),
              subtitle: Text(
                '${contact.onionAddress.substring(0, 16)}...',
                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
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
