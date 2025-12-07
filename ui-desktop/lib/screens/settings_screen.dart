import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tor_messenger_ui/services/chat_provider.dart';
import 'package:tor_messenger_ui/theme/app_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Storage data - refreshed on demand
  Map<String, int>? _storageData;
  bool _loadingStorage = true;

  @override
  void initState() {
    super.initState();
    _loadStorageUsage();
  }

  Future<void> _loadStorageUsage() async {
    if (!mounted) return;
    setState(() => _loadingStorage = true);
    
    try {
      final chatProvider = Provider.of<ChatProvider>(context, listen: false);
      final data = await chatProvider.getStorageUsage();
      if (mounted) {
        setState(() {
          _storageData = data;
          _loadingStorage = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _storageData = {'total': 0, 'chat': 0, 'system': 0};
          _loadingStorage = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.darkBackground,
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: AppTheme.sidebarBackground,
        foregroundColor: AppTheme.textPrimary,
        elevation: 1,
      ),
      body: Consumer<ChatProvider>(
        builder: (context, chatProvider, _) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildSectionHeader('Privacy'),
              _buildBlockedContactsSection(context, chatProvider),
              
              const SizedBox(height: 24),
              _buildSectionHeader('Notifications'),
              SwitchListTile(
                title: const Text('Show Notifications', style: TextStyle(color: AppTheme.textPrimary)),
                value: chatProvider.notificationsEnabled,
                activeColor: AppTheme.primaryPurple,
                onChanged: (value) => chatProvider.toggleNotifications(value),
              ),
              SwitchListTile(
                title: const Text('Play Sound', style: TextStyle(color: AppTheme.textPrimary)),
                value: chatProvider.soundEnabled,
                activeColor: AppTheme.primaryPurple,
                onChanged: (value) => chatProvider.toggleSound(value),
              ),

              const SizedBox(height: 24),
              _buildSectionHeader('Storage'),
              _buildStorageSection(context, chatProvider),
              
              const SizedBox(height: 24),
              
              const SizedBox(height: 24),
              _buildSectionHeader('Chats'),
              _buildActionTile(
                context,
                title: 'Clear All Chats',
                icon: Icons.clear_all,
                color: Colors.orange,
                onTap: () => _confirmAction(context, 'Clear All Chats', 'Are you sure you want to clear all messages? This cannot be undone.', chatProvider.clearAllChats),
              ),
              _buildActionTile(
                context,
                title: 'Archive All Chats',
                icon: Icons.archive,
                color: Colors.blue,
                onTap: () => _confirmAction(context, 'Archive All Chats', 'Are you sure you want to archive all chats?', chatProvider.archiveAllChats),
              ),
              _buildActionTile(
                context,
                title: 'Delete All Chats',
                icon: Icons.delete_forever,
                color: Colors.red,
                onTap: () => _confirmAction(context, 'Delete All Chats', 'Are you sure you want to delete all chats and messages? This is irreversible.', chatProvider.deleteAllChats),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: AppTheme.primaryPurple,
          fontWeight: FontWeight.bold,
          fontSize: 13,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildBlockedContactsSection(BuildContext context, ChatProvider provider) {
    if (provider.blockedContacts.isEmpty) {
      return const ListTile(
        title: Text('Blocked Contacts', style: TextStyle(color: AppTheme.textPrimary)),
        subtitle: Text('No blocked contacts', style: TextStyle(color: AppTheme.textSecondary)),
        leading: Icon(Icons.block, color: AppTheme.textSecondary),
      );
    }
    
    return ExpansionTile(
      leading: const Icon(Icons.block, color: AppTheme.textSecondary),
      title: Text('Blocked Contacts (${provider.blockedContacts.length})', 
        style: const TextStyle(color: AppTheme.textPrimary)),
      children: provider.blockedContacts.map((onion) {
        return ListTile(
          title: Text(onion, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
          trailing: TextButton(
             onPressed: () => provider.unblockContact(onion),
             child: const Text('Unblock', style: TextStyle(color: AppTheme.primaryPurple)),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildStorageSection(BuildContext context, ChatProvider chatProvider) {
    if (_loadingStorage) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator(color: AppTheme.primaryPurple)),
      );
    }

    final data = _storageData ?? {'total': 0, 'chat': 0, 'system': 0};
    final total = _formatBytes(data['total']!);
    final chat = _formatBytes(data['chat']!);
    final system = _formatBytes(data['system']!);

    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.sd_storage, color: AppTheme.textSecondary),
          title: Text('Total Usage: $total', style: const TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold)),
          trailing: IconButton(
            icon: const Icon(Icons.refresh, color: AppTheme.textSecondary),
            onPressed: _loadStorageUsage,
            tooltip: 'Refresh',
          ),
        ),
        _buildStorageItem(
          context, 
          'Messages & Contacts', 
          chat, 
          Icons.chat_bubble_outline,
          () => _confirmActionAndRefresh(context, 'Clear Messages', 'This will delete ALL message history and contacts. Tor data will be preserved.', chatProvider.deleteAllChats),
        ),
        _buildStorageItem(
          context, 
          'System Data & Cache', 
          system, 
          Icons.dns,
          () => _confirmActionAndRefresh(context, 'Clear System Cache', 'This will delete temporary Tor files. The app may take longer to connect next time.', chatProvider.clearSystemCache),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            'System data specific to Tor (consensus, descriptors) is required for connectivity.',
            style: TextStyle(color: AppTheme.textSecondary.withOpacity(0.7), fontSize: 12),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmActionAndRefresh(BuildContext context, String title, String content, Future<void> Function() action) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.sidebarBackground,
        title: Text(title, style: const TextStyle(color: AppTheme.textPrimary)),
        content: Text(content, style: const TextStyle(color: AppTheme.textPrimary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );

    if (confirm == true && context.mounted) {
      await action();
      // Refresh storage after clearing
      await _loadStorageUsage();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Action completed')));
      }
    }
  }

  Widget _buildActionTile(BuildContext context, {required String title, required IconData icon, required Color color, required VoidCallback onTap}) {
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title, style: TextStyle(color: color)),
      onTap: onTap,
    );
  }

  Future<void> _confirmAction(BuildContext context, String title, String content, Future<void> Function() action) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.sidebarBackground,
        title: Text(title, style: const TextStyle(color: AppTheme.textPrimary)),
        content: Text(content, style: const TextStyle(color: AppTheme.textPrimary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );

    if (confirm == true && context.mounted) {
      await action();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Action completed')));
      }
    }
  }
  Widget _buildStorageItem(BuildContext context, String title, String size, IconData icon, VoidCallback onClear) {
    return ListTile(
      leading: const SizedBox(width: 24), // Indent
      title: Row(
        children: [
          Icon(icon, size: 16, color: AppTheme.textSecondary),
          const SizedBox(width: 8),
          Text(title, style: const TextStyle(color: AppTheme.textPrimary)),
          const Spacer(),
          Text(size, style: const TextStyle(color: AppTheme.textSecondary)),
        ],
      ),
      trailing: TextButton(
        onPressed: onClear,
        child: const Text('Clear', style: TextStyle(color: Colors.red)),
      ),
    );
  }

  String _formatBytes(int bytes) {
      if (bytes < 1024) return "$bytes B";
      if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
      if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
      return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB";
  }
}
