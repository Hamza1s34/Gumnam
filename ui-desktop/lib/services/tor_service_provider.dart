import 'package:flutter/material.dart';
import 'package:tor_messenger_ui/generated/rust_bridge/frb_generated.dart';

class TorServiceProvider extends ChangeNotifier {
  String _onionAddress = '';
  bool _isReady = false;
  String _status = 'Disconnected';

  String get onionAddress => _onionAddress;
  bool get isReady => _isReady;
  String get status => _status;

  Future<void> init() async {
    debugPrint('[TorServiceProvider] Initializing Tor...');
    _status = 'Starting Tor...';
    notifyListeners();

    try {
      debugPrint('[TorServiceProvider] Calling RustLib.startTor()...');
      _onionAddress = await RustLib.instance.api.crateApiStartTor();
      debugPrint('[TorServiceProvider] Tor started! Onion: $_onionAddress');
      _isReady = true;
      _status = 'Connected';
    } catch (e) {
      debugPrint('[TorServiceProvider] Error starting Tor: $e');
      _status = 'Error: $e';
      _isReady = false;
    }
    notifyListeners();
  }

  Future<void> sendMessageToAddress(String address, String message) async {
    debugPrint('[TorServiceProvider] sendMessageToAddress: $address');
    try {
      await RustLib.instance.api.crateApiSendMessage(onionAddress: address, message: message);
      debugPrint('[TorServiceProvider] Message sent successfully');
    } catch (e) {
      debugPrint('[TorServiceProvider] Error sending message: $e');
      rethrow;
    }
  }
}
