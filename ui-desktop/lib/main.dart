import 'package:flutter/material.dart';
import 'package:tor_messenger_ui/screens/home_screen.dart';
import 'package:tor_messenger_ui/theme/app_theme.dart';

import 'package:tor_messenger_ui/generated/rust_bridge/frb_generated.dart';

import 'package:provider/provider.dart';
import 'package:tor_messenger_ui/services/tor_service_provider.dart';
import 'package:tor_messenger_ui/services/chat_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const TorMessengerApp());
}

class TorMessengerApp extends StatelessWidget {
  const TorMessengerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => TorServiceProvider()..init()),
        ChangeNotifierProvider(create: (_) => ChatProvider()..loadContacts()),
      ],
      child: MaterialApp(
        title: 'Tor Messenger',
        theme: AppTheme.darkTheme,
        home: const HomeScreen(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
