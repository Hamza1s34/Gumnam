import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:tor_messenger_ui/generated/rust_bridge/api.dart';
import 'package:tor_messenger_ui/services/chat_provider.dart';
import 'package:tor_messenger_ui/theme/app_theme.dart';

class ContactInfoView extends StatefulWidget {
  final String onionAddress;
  final VoidCallback onBack;

  const ContactInfoView({
    super.key,
    required this.onionAddress,
    required this.onBack,
  });

  @override
  State<ContactInfoView> createState() => _ContactInfoViewState();
}

class _ContactInfoViewState extends State<ContactInfoView> {
  ContactDetails? _details;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadContactDetails();
  }

  Future<void> _loadContactDetails() async {
    try {
      final details = await getContactDetails(onionAddress: widget.onionAddress);
      setState(() {
        _details = details;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  String _formatDateTime(int? timestamp) {
    if (timestamp == null) return 'Never';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    return DateFormat('MMM d, yyyy HH:mm').format(date);
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied to clipboard')),
    );
  }

  Future<void> _resendHandshake() async {
    try {
      await sendHandshakeToContact(onionAddress: widget.onionAddress);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Handshake sent successfully'),
            backgroundColor: Colors.green,
          ),
        );
        // Reload contact details after handshake
        _loadContactDetails();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send handshake: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // Sanitize text to handle malformed UTF-16 characters
  String _sanitizeText(String text) {
    if (text.isEmpty) return text;
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
      }
      return buffer.toString().isEmpty ? '?' : buffer.toString();
    } catch (e) {
      return text.replaceAll(RegExp(r'[^\x00-\x7F]'), '?');
    }
  }

  Future<void> _showEditNicknameDialog() async {
    if (_details == null) return;
    
    final controller = TextEditingController(text: _details!.nickname);
    
    final newNickname = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.sidebarBackground,
        title: const Text('Edit Nickname', style: TextStyle(color: AppTheme.textPrimary)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: AppTheme.textPrimary),
          decoration: InputDecoration(
            hintText: 'Enter nickname',
            hintStyle: TextStyle(color: AppTheme.textSecondary.withOpacity(0.5)),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: AppTheme.textSecondary.withOpacity(0.3)),
              borderRadius: BorderRadius.circular(8),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: const BorderSide(color: AppTheme.primaryPurple),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryPurple,
              foregroundColor: Colors.white,
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    
    if (newNickname != null && newNickname.isNotEmpty && newNickname != _details!.nickname) {
      try {
        await updateContactNickname(
          onionAddress: widget.onionAddress,
          nickname: newNickname,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Nickname updated'),
              backgroundColor: Colors.green,
            ),
          );
          _loadContactDetails();  // Reload to show new nickname
          // Also reload contacts in ChatProvider to update sidebar and header
          if (mounted) {
            context.read<ChatProvider>().loadContacts();
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to update nickname: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.chatBackground,
      child: Column(
        children: [
          // Header with back button
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: AppTheme.sidebarBackground,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: widget.onBack,
                  tooltip: 'Back to chat',
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  backgroundColor: AppTheme.primaryPurple,
                  child: const Icon(Icons.person, color: Colors.white),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Contact Information',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _loadContactDetails,
                  tooltip: 'Refresh',
                ),
              ],
            ),
          ),

          // Content
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.error_outline, size: 48, color: Colors.red),
                            const SizedBox(height: 16),
                            Text('Error: $_error', style: const TextStyle(color: Colors.red)),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: _loadContactDetails,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      )
                    : _details != null
                        ? _buildDetailsContent(_details!)
                        : const Center(child: Text('No data')),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailsContent(ContactDetails details) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Profile header
          Center(
            child: Column(
              children: [
                CircleAvatar(
                  radius: 50,
                  backgroundColor: AppTheme.primaryPurple,
                  child: Text(
                    _sanitizeText(details.nickname).isNotEmpty 
                        ? _sanitizeText(details.nickname)[0].toUpperCase() 
                        : '?',
                    style: const TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _sanitizeText(details.nickname),
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.edit, size: 20),
                      onPressed: _showEditNicknameDialog,
                      tooltip: 'Edit nickname',
                      color: AppTheme.primaryPurple,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: details.publicKey != null 
                        ? Colors.green.withOpacity(0.2) 
                        : Colors.orange.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        details.publicKey != null ? Icons.verified_user : Icons.warning,
                        size: 16,
                        color: details.publicKey != null ? Colors.green : Colors.orange,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        details.publicKey != null ? 'Key Exchanged' : 'No Key Exchange',
                        style: TextStyle(
                          color: details.publicKey != null ? Colors.green : Colors.orange,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 32),
          const Divider(color: AppTheme.textSecondary),
          const SizedBox(height: 16),

          // Onion Address section
          _buildSection(
            title: 'Onion Address',
            icon: Icons.link,
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(
                    details.onionAddress,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.textPrimary,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 20),
                  onPressed: () => _copyToClipboard(details.onionAddress, 'Address'),
                  tooltip: 'Copy address',
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Public Key section
          _buildSection(
            title: 'Public Key',
            icon: Icons.key,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (details.publicKey != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: SelectableText(
                            details.publicKey!,
                            style: const TextStyle(
                              fontSize: 10,
                              color: AppTheme.textSecondary,
                              fontFamily: 'monospace',
                            ),
                            maxLines: 5,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy, size: 20),
                          onPressed: () => _copyToClipboard(details.publicKey!, 'Public key'),
                          tooltip: 'Copy public key',
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  const Text(
                    'Not yet exchanged',
                    style: TextStyle(color: Colors.orange),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton.icon(
                    onPressed: _resendHandshake,
                    icon: const Icon(Icons.handshake),
                    label: const Text('Send Handshake'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryPurple,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Message Statistics section
          _buildSection(
            title: 'Message Statistics',
            icon: Icons.analytics,
            child: Column(
              children: [
                _buildStatRow('Total Messages', '${details.totalMessages}'),
                const SizedBox(height: 8),
                _buildStatRow('First Message', _formatDateTime(details.firstMessageTime)),
                const SizedBox(height: 8),
                _buildStatRow('Last Message', _formatDateTime(details.lastMessageTime)),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Last Seen section
          _buildSection(
            title: 'Activity',
            icon: Icons.access_time,
            child: _buildStatRow('Last Seen', _formatDateTime(details.lastSeen)),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required IconData icon,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 20, color: AppTheme.primaryPurple),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: AppTheme.textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.only(left: 28),
          child: child,
        ),
      ],
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        Text(
          value,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
