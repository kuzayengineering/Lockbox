import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';

import 'state/app_state.dart';
import 'ui/library_screen.dart';
import 'ui/lock_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Windows plays video with libmpv; Android uses its own ExoPlayer.
  if (Platform.isWindows) MediaKit.ensureInitialized();
  final app = AppState()..init();
  runApp(ChangeNotifierProvider.value(value: app, child: const LockboxApp()));
}

final navigatorKey = GlobalKey<NavigatorState>();

class LockboxApp extends StatelessWidget {
  const LockboxApp({super.key});

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3F51B5), brightness: b),
        );
    return MaterialApp(
      title: 'Lockbox',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const _Root(),
    );
  }
}

class _Root extends StatefulWidget {
  const _Root();
  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  Phase? _last;

  @override
  Widget build(BuildContext context) {
    final phase = context.select<AppState, Phase>((a) => a.phase);
    if (_last == Phase.unlocked && phase != Phase.unlocked) {
      // Locked: close every open screen (viewer, settings…) immediately.
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => navigatorKey.currentState?.popUntil((r) => r.isFirst));
    }
    _last = phase;
    return switch (phase) {
      Phase.loading => const Scaffold(body: Center(child: CircularProgressIndicator())),
      Phase.setup => const LockScreen(key: ValueKey('setup'), setup: true),
      Phase.locked => const LockScreen(key: ValueKey('locked'), setup: false),
      Phase.unlocked => const LibraryScreen(),
    };
  }
}
