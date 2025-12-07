import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:tor_messenger_ui/generated/rust_bridge/api.dart';
import 'package:tor_messenger_ui/theme/app_theme.dart';

class ContactInfoDialog extends StatefulWidget {
  final String onionAddress;

  const ContactInfoDialog({super.key, required this.onionAddress});

  @override
  State<ContactInfoDialog> createState() => _ContactInfoDialogState();
}

class _ContactInfoDialogState extends State<ContactInfoDialog> {
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
    return DateFormat('MMM d, yyyy h:mm a').format(date);
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

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppTheme.sidebarBackground,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        width: 450,
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
                  const Icon(Icons.info_outline, color: AppTheme.primaryPurple),
                  const SizedBox(width: 12),
                  const Text(
                    'Contact Information',
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

            // Content
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.all(32),
                child: CircularProgressIndicator(),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Error: $_error', style: const TextStyle(color: Colors.red)),
              )
            else if (_details != null)
              _buildDetailsContent(_details!),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailsContent(ContactDetails details) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Nickname
          _buildInfoRow(
            icon: Icons.person,
            label: 'Nickname',
            value: details.nickname,
          ),

          const Divider(color: AppTheme.textSecondary, height: 24),

          // Onion Address
          _buildInfoRow(
            icon: Icons.link,
            label: 'Onion Address',
            value: details.onionAddress,
            isCopyable: true,
            onCopy: () => _copyToClipboard(details.onionAddress, 'Address'),
          ),

          const Divider(color: AppTheme.textSecondary, height: 24),

          // Public Key
          _buildInfoRow(
            icon: Icons.key,
            label: 'Public Key',
            value: details.publicKey ?? 'Not exchanged yet',
            isCopyable: details.publicKey != null,
            onCopy: details.publicKey != null
                ? () => _copyToClipboard(details.publicKey!, 'Public key')
                : null,
            isMultiline: true,
            valueColor: details.publicKey != null ? AppTheme.textPrimary : Colors.orange,
          ),

          if (details.publicKey == null) ...[
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: _resendHandshake,
              icon: const Icon(Icons.handshake, size: 18),
              label: const Text('Send Handshake'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryPurple,
                foregroundColor: Colors.white,
              ),
            ),
          ],

          const Divider(color: AppTheme.textSecondary, height: 24),

          // Message Statistics
          _buildInfoRow(
            icon: Icons.chat_bubble_outline,
            label: 'Total Messages',
            value: '${details.totalMessages}',
          ),

          const SizedBox(height: 12),

          _buildInfoRow(
            icon: Icons.first_page,
            label: 'First Message',
            value: _formatDateTime(details.firstMessageTime),
          ),

          const SizedBox(height: 12),

          _buildInfoRow(
            icon: Icons.last_page,
            label: 'Last Message',
            value: _formatDateTime(details.lastMessageTime),
          ),

          const Divider(color: AppTheme.textSecondary, height: 24),

          // Last Seen
          _buildInfoRow(
            icon: Icons.access_time,
            label: 'Last Seen',
            value: _formatDateTime(details.lastSeen),
          ),

          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildInfoRow({
    required IconData icon,
    required String label,
    required String value,
    bool isCopyable = false,
    VoidCallback? onCopy,
    bool isMultiline = false,
    Color? valueColor,
  }) {
    return Row(
      crossAxisAlignment: isMultiline ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        Icon(icon, size: 20, color: AppTheme.textSecondary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 2),
              SelectableText(
                value,
                style: TextStyle(
                  fontSize: isMultiline ? 11 : 14,
                  color: valueColor ?? AppTheme.textPrimary,
                  fontFamily: isMultiline ? 'monospace' : null,
                ),
                maxLines: isMultiline ? 4 : 1,
              ),
            ],
          ),
        ),
        if (isCopyable && onCopy != null)
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            onPressed: onCopy,
            color: AppTheme.textSecondary,
            tooltip: 'Copy',
          ),
      ],
    );
  }
}
