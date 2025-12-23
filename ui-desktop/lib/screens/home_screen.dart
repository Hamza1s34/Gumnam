import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:gumnam/services/chat_provider.dart';
import 'package:gumnam/services/tor_service_provider.dart';
import 'package:gumnam/widgets/sidebar/sidebar.dart';
import 'package:gumnam/widgets/chat/chat_area.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _pollingStarted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    
    // Start polling when Tor is ready
    final torProvider = context.watch<TorServiceProvider>();
    if (torProvider.isReady && !_pollingStarted) {
      _pollingStarted = true;
      context.read<ChatProvider>().startPolling();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          const SizedBox(
            width: 350,
            child: Sidebar(),
          ),
          const VerticalDivider(width: 1, thickness: 1, color: Colors.white10),
          const Expanded(
            child: ChatArea(),
          ),
        ],
      ),
    );
  }
}
