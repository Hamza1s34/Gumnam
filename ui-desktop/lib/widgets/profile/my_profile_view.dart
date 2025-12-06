import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:tor_messenger_ui/generated/rust_bridge/api.dart';
import 'package:tor_messenger_ui/services/tor_service_provider.dart';
import 'package:tor_messenger_ui/theme/app_theme.dart';

class MyProfileView extends StatefulWidget {
  final VoidCallback onBack;

  const MyProfileView({super.key, required this.onBack});

  @override
  State<MyProfileView> createState() => _MyProfileViewState();
}

class _MyProfileViewState extends State<MyProfileView> {
  String? _publicKey;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPublicKey();
  }

  Future<void> _loadPublicKey() async {
    try {
      final pk = await getMyPublicKey();
      setState(() {
        _publicKey = pk;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied to clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.chatBackground,
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: AppTheme.sidebarBackground,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: widget.onBack,
                  tooltip: 'Back',
                ),
                const SizedBox(width: 8),
                const CircleAvatar(
                  backgroundColor: AppTheme.primaryPurple,
                  child: Icon(Icons.person, color: Colors.white),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'My Profile',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Content
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Profile avatar
                        Center(
                          child: Column(
                            children: [
                              const CircleAvatar(
                                radius: 50,
                                backgroundColor: AppTheme.primaryPurple,
                                child: Icon(Icons.person, size: 50, color: Colors.white),
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                'My Identity',
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: AppTheme.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 8),
                              _buildStatusBadge(),
                            ],
                          ),
                        ),

                        const SizedBox(height: 32),
                        const Divider(color: AppTheme.textSecondary),
                        const SizedBox(height: 16),

                        // Onion Address section
                        _buildSection(
                          title: 'My Onion Address',
                          icon: Icons.link,
                          child: Consumer<TorServiceProvider>(
                            builder: (context, tor, child) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
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
                                            tor.isReady
                                                ? tor.onionAddress
                                                : 'Not connected',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: tor.isReady
                                                  ? AppTheme.textPrimary
                                                  : Colors.orange,
                                              fontFamily: 'monospace',
                                            ),
                                          ),
                                        ),
                                        if (tor.isReady)
                                          IconButton(
                                            icon: const Icon(Icons.copy, size: 20),
                                            onPressed: () => _copyToClipboard(
                                                tor.onionAddress, 'Onion address'),
                                            tooltip: 'Copy address',
                                          ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Share this address with others so they can contact you',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.textSecondary.withOpacity(0.7),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),

                        const SizedBox(height: 24),

                        // Status section
                        _buildSection(
                          title: 'Tor Status',
                          icon: Icons.wifi,
                          child: Consumer<TorServiceProvider>(
                            builder: (context, tor, child) {
                              return Row(
                                children: [
                                  Container(
                                    width: 12,
                                    height: 12,
                                    decoration: BoxDecoration(
                                      color: tor.isReady ? Colors.green : Colors.orange,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    tor.isReady ? 'Connected & Ready' : tor.status,
                                    style: TextStyle(
                                      color: tor.isReady ? Colors.green : Colors.orange,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),

                        const SizedBox(height: 24),

                        // Public Key section
                        _buildSection(
                          title: 'My Public Key',
                          icon: Icons.key,
                          child: _error != null
                              ? Text('Error: $_error',
                                  style: const TextStyle(color: Colors.red))
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: Colors.black26,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            child: SelectableText(
                                              _publicKey ?? 'Loading...',
                                              style: const TextStyle(
                                                fontSize: 10,
                                                color: AppTheme.textSecondary,
                                                fontFamily: 'monospace',
                                              ),
                                              maxLines: 8,
                                            ),
                                          ),
                                          if (_publicKey != null)
                                            IconButton(
                                              icon: const Icon(Icons.copy, size: 20),
                                              onPressed: () => _copyToClipboard(
                                                  _publicKey!, 'Public key'),
                                              tooltip: 'Copy public key',
                                            ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Your public key is used to encrypt messages sent to you',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: AppTheme.textSecondary.withOpacity(0.7),
                                      ),
                                    ),
                                  ],
                                ),
                        ),

                        const SizedBox(height: 24),

                        // Security Info
                        _buildSection(
                          title: 'Security Information',
                          icon: Icons.security,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildInfoRow(Icons.lock, 'End-to-end encrypted'),
                              const SizedBox(height: 8),
                              _buildInfoRow(Icons.visibility_off, 'Anonymous via Tor'),
                              const SizedBox(height: 8),
                              _buildInfoRow(Icons.vpn_key, 'RSA-2048 encryption'),
                            ],
                          ),
                        ),

                        const SizedBox(height: 32),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge() {
    return Consumer<TorServiceProvider>(
      builder: (context, tor, child) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: tor.isReady
                ? Colors.green.withOpacity(0.2)
                : Colors.orange.withOpacity(0.2),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                tor.isReady ? Icons.check_circle : Icons.hourglass_empty,
                size: 16,
                color: tor.isReady ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 6),
              Text(
                tor.isReady ? 'Online' : 'Connecting...',
                style: TextStyle(
                  color: tor.isReady ? Colors.green : Colors.orange,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        );
      },
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

  Widget _buildInfoRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Colors.green),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(color: AppTheme.textPrimary),
        ),
      ],
    );
  }
}
