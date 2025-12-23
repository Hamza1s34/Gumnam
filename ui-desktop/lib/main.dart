import 'package:flutter/material.dart';
import 'package:gumnam/screens/home_screen.dart';
import 'package:gumnam/theme/app_theme.dart';

import 'package:gumnam/generated/rust_bridge/frb_generated.dart';

import 'package:provider/provider.dart';
import 'package:gumnam/services/tor_service_provider.dart';
import 'package:gumnam/services/chat_provider.dart';

import 'package:local_notifier/local_notifier.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  await windowManager.ensureInitialized();
  await localNotifier.setup(
    appName: 'Gumnam',
    // The parameter shortcutPolicy only works on Windows
    shortcutPolicy: ShortcutPolicy.requireCreate,
  );

  await RustLib.init();
  runApp(const GumnamApp());
}

class GumnamApp extends StatelessWidget {
  const GumnamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => TorServiceProvider()..init()),
        ChangeNotifierProvider(create: (_) => ChatProvider()..loadContacts()),
      ],
      child: MaterialApp(
        title: 'Gumnam',
        theme: AppTheme.darkTheme,
        home: const HomeScreen(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
