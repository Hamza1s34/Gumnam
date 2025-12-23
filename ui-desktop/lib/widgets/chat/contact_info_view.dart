import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gumnam/generated/rust_bridge/api.dart';
import 'package:gumnam/services/chat_provider.dart';
import 'package:gumnam/theme/app_theme.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

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

class _ContactInfoViewState extends State<ContactInfoView> with SingleTickerProviderStateMixin {
  ContactDetails? _details;
  bool _isLoading = true;
  String? _error;
  late TabController _tabController;
  bool _autoSaveMedia = false;

  // Media lists
  List<dynamic> _images = [];
  List<dynamic> _audioMessages = [];
  List<dynamic> _links = [];
  List<dynamic> _files = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _loadContactDetails();
    _loadAutoSavePreference();
    _loadMediaFromChat();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadAutoSavePreference() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _autoSaveMedia = prefs.getBool('auto_save_media_${widget.onionAddress}') ?? false;
    });
  }

  Future<void> _setAutoSavePreference(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_save_media_${widget.onionAddress}', value);
    setState(() {
      _autoSaveMedia = value;
    });
  }

  void _loadMediaFromChat() {
    final chatProvider = context.read<ChatProvider>();
    final messages = chatProvider.messages;

    final images = <dynamic>[];
    final audio = <dynamic>[];
    final links = <dynamic>[];
    final files = <dynamic>[];

    // Regular expression to find URLs
    final urlRegex = RegExp(
      r'https?://[^\s<>\[\]{}|\\^`"]+',
      caseSensitive: false,
    );

    for (final msg in messages) {
      if (msg.msgType == 'image') {
        images.add(msg);
      } else if (msg.msgType == 'audio') {
        audio.add(msg);
      } else if (msg.msgType == 'file') {
        files.add(msg);
      } else {
        // Check for links in text messages
        final text = msg.text ?? '';
        if (urlRegex.hasMatch(text)) {
          links.add(msg);
        }
      }
    }

    setState(() {
      _images = images;
      _audioMessages = audio;
      _links = links;
      _files = files;
    });
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
                Expanded(
                  child: Text(
                    _details != null ? _sanitizeText(_details!.nickname) : 'Contact Info',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () {
                    _loadContactDetails();
                    _loadMediaFromChat();
                  },
                  tooltip: 'Refresh',
                ),
              ],
            ),
          ),

          // Tab bar
          Container(
            color: AppTheme.sidebarBackground,
            child: TabBar(
              controller: _tabController,
              isScrollable: true,
              indicatorColor: AppTheme.primaryPurple,
              labelColor: AppTheme.primaryPurple,
              unselectedLabelColor: AppTheme.textSecondary,
              tabs: [
                const Tab(icon: Icon(Icons.info_outline), text: 'Info'),
                Tab(icon: const Icon(Icons.image), text: 'Images (${_images.length})'),
                Tab(icon: const Icon(Icons.mic), text: 'Audio (${_audioMessages.length})'),
                Tab(icon: const Icon(Icons.link), text: 'Links (${_links.length})'),
                Tab(icon: const Icon(Icons.insert_drive_file), text: 'Files (${_files.length})'),
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
                        ? TabBarView(
                            controller: _tabController,
                            children: [
                              _buildDetailsContent(_details!),
                              _buildImagesTab(),
                              _buildAudioTab(),
                              _buildLinksTab(),
                              _buildFilesTab(),
                            ],
                          )
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
          // Auto-save media toggle
          Container(
            margin: const EdgeInsets.only(bottom: 24),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.sidebarBackground,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.download, color: AppTheme.primaryPurple),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Auto-save Media',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        'Automatically save received media to Downloads',
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _autoSaveMedia,
                  onChanged: _setAutoSavePreference,
                  activeColor: AppTheme.primaryPurple,
                ),
              ],
            ),
          ),

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
                // ECIES Encryption Status (always secure with onion address)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.verified_user,
                        size: 16,
                        color: Colors.green,
                      ),
                      SizedBox(width: 6),
                      Text(
                        'ECIES Encrypted',
                        style: TextStyle(
                          color: Colors.green,
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

          // Encryption section (ECIES - no handshake needed)
          _buildSection(
            title: 'Encryption',
            icon: Icons.lock,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green.withOpacity(0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.verified_user, color: Colors.green),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'ECIES (Ed25519-X25519)',
                          style: TextStyle(
                            color: Colors.green,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'End-to-end encryption using onion address keys',
                          style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
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

  // Images Tab
  Widget _buildImagesTab() {
    if (_images.isEmpty) {
      return _buildEmptyState('No images', Icons.image_outlined);
    }

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: _images.length,
      itemBuilder: (context, index) {
        final msg = _images[index];
        return _buildImageTile(msg);
      },
    );
  }

  Widget _buildImageTile(dynamic msg) {
    try {
      final bytes = base64Decode(msg.text.replaceAll('\n', ''));
      return GestureDetector(
        onTap: () => _showImageFullScreen(bytes, msg),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: Colors.black26,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.grey),
                ),
                Positioned(
                  bottom: 4,
                  right: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _formatTime(msg.timestamp),
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: Colors.black26,
        ),
        child: const Icon(Icons.broken_image, color: Colors.grey),
      );
    }
  }

  void _showImageFullScreen(Uint8List bytes, dynamic msg) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                child: Image.memory(bytes),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.download, color: Colors.white),
                    onPressed: () => _saveImageToDownloads(bytes, msg.id),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Audio Tab
  Widget _buildAudioTab() {
    if (_audioMessages.isEmpty) {
      return _buildEmptyState('No voice messages', Icons.mic_none);
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _audioMessages.length,
      itemBuilder: (context, index) {
        final msg = _audioMessages[index];
        return _buildAudioTile(msg);
      },
    );
  }

  Widget _buildAudioTile(dynamic msg) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.sidebarBackground,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.primaryPurple.withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.mic, color: AppTheme.primaryPurple),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Voice Message',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  _formatDateTime(msg.timestamp),
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.download, color: AppTheme.primaryPurple),
            onPressed: () => _saveAudioToDownloads(msg),
          ),
        ],
      ),
    );
  }

  // Links Tab
  Widget _buildLinksTab() {
    if (_links.isEmpty) {
      return _buildEmptyState('No links', Icons.link_off);
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _links.length,
      itemBuilder: (context, index) {
        final msg = _links[index];
        return _buildLinkTile(msg);
      },
    );
  }

  Widget _buildLinkTile(dynamic msg) {
    final text = msg.text ?? '';
    final urlRegex = RegExp(r'https?://[^\s<>\[\]{}|\\^`"]+', caseSensitive: false);
    final matches = urlRegex.allMatches(text);
    final urls = matches.map((m) => m.group(0)!).toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.sidebarBackground,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final url in urls)
            InkWell(
              onTap: () => _copyToClipboard(url, 'Link'),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    const Icon(Icons.link, color: AppTheme.primaryPurple, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        url,
                        style: const TextStyle(
                          color: Colors.blue,
                          decoration: TextDecoration.underline,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 18, color: AppTheme.textSecondary),
                      onPressed: () => _copyToClipboard(url, 'Link'),
                    ),
                  ],
                ),
              ),
            ),
          Text(
            _formatDateTime(msg.timestamp),
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  // Files Tab
  Widget _buildFilesTab() {
    if (_files.isEmpty) {
      return _buildEmptyState('No files', Icons.folder_open);
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _files.length,
      itemBuilder: (context, index) {
        final msg = _files[index];
        return _buildFileTile(msg);
      },
    );
  }

  Widget _buildFileTile(dynamic msg) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.sidebarBackground,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.primaryPurple.withOpacity(0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.insert_drive_file, color: AppTheme.primaryPurple),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'File',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  _formatDateTime(msg.timestamp),
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.download, color: AppTheme.primaryPurple),
            onPressed: () => _saveFileToDownloads(msg),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(String message, IconData icon) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: AppTheme.textSecondary.withOpacity(0.5)),
          const SizedBox(height: 16),
          Text(
            message,
            style: TextStyle(
              color: AppTheme.textSecondary.withOpacity(0.7),
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    return DateFormat('h:mm a').format(date);
  }

  Future<void> _saveImageToDownloads(Uint8List bytes, String msgId) async {
    try {
      final downloadsDir = await _getDownloadsDirectory();
      final fileName = 'image_$msgId.png';
      final file = File('${downloadsDir.path}/$fileName');
      await file.writeAsBytes(bytes);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Image saved to Downloads: $fileName'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save image: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _saveAudioToDownloads(dynamic msg) async {
    try {
      final bytes = base64Decode(msg.text.replaceAll('\n', ''));
      final downloadsDir = await _getDownloadsDirectory();
      final fileName = 'audio_${msg.id}.m4a';
      final file = File('${downloadsDir.path}/$fileName');
      await file.writeAsBytes(bytes);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Audio saved to Downloads: $fileName'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save audio: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _saveFileToDownloads(dynamic msg) async {
    try {
      final bytes = base64Decode(msg.text.replaceAll('\n', ''));
      final downloadsDir = await _getDownloadsDirectory();
      final fileName = 'file_${msg.id}';
      final file = File('${downloadsDir.path}/$fileName');
      await file.writeAsBytes(bytes);
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('File saved to Downloads: $fileName'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save file: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<Directory> _getDownloadsDirectory() async {
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      return Directory('$home/Downloads');
    } else if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      return Directory('$userProfile\\Downloads');
    } else {
      // Linux and others
      final home = Platform.environment['HOME'];
      return Directory('$home/Downloads');
    }
  }
}