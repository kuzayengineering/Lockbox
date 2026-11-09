import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../core/vault.dart';
import '../platform/native.dart';
import '../state/app_state.dart';
import 'common.dart' show TaskBanner;

/// Unlock screen (vault exists) or first-run setup (no vault yet).
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.setup});
  final bool setup;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _pass = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;
  String? _dir;

  @override
  void initState() {
    super.initState();
    if (widget.setup) {
      context.read<AppState>().defaultVaultDir().then((d) {
        if (mounted) setState(() => _dir = d);
      });
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on WrongPassphraseException {
      _error = 'Wrong passcode';
      _pass.clear();
    } catch (e) {
      _error = e.toString();
    }
    if (mounted) setState(() => _busy = false);
  }

  void _unlock() {
    if (_pass.text.isEmpty) return;
    _run(() => context.read<AppState>().unlock(_pass.text));
  }

  void _create() {
    final p = _pass.text;
    if (p.length < 8) {
      setState(() => _error = 'Use at least 8 characters.');
      return;
    }
    if (p != _confirm.text) {
      setState(() => _error = 'The two passcodes don\'t match.');
      return;
    }
    _run(() => context.read<AppState>().createVault(p, dir: _dir));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final theme = Theme.of(context);
    final strength = _strength(_pass.text);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Image.asset('assets/icon/emblem.png',
                        height: 140, filterQuality: FilterQuality.medium),
                  ),
                  const SizedBox(height: 12),
                  Text('Lockbox',
                      textAlign: TextAlign.center, style: theme.textTheme.headlineMedium),
                  const SizedBox(height: 8),
                  Text(
                    widget.setup
                        ? 'Create a passcode for your private vault.\n'
                            'There is no way to recover it if you forget it.'
                        : 'Enter your passcode',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _pass,
                    obscureText: _obscure,
                    autofocus: true,
                    enabled: !_busy,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => widget.setup ? null : _unlock(),
                    decoration: InputDecoration(
                      labelText: 'Passcode',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  if (widget.setup) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: strength.$1,
                      color: strength.$3,
                      backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    ),
                    const SizedBox(height: 4),
                    Text(strength.$2, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _confirm,
                      obscureText: _obscure,
                      enabled: !_busy,
                      onSubmitted: (_) => _create(),
                      decoration: const InputDecoration(
                          labelText: 'Confirm passcode', border: OutlineInputBorder()),
                    ),
                    if (!Native.isAndroid && _dir != null) ...[
                      const SizedBox(height: 16),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.folder_outlined),
                        title: const Text('Vault folder'),
                        subtitle: Text(_dir!),
                        trailing: TextButton(
                          onPressed: _busy
                              ? null
                              : () async {
                                  final d = await Native.pickFolder(
                                      title: 'Where should the vault be stored?');
                                  if (d != null) setState(() => _dir = p.join(d, 'Lockbox Vault'));
                                },
                          child: const Text('Change'),
                        ),
                      ),
                    ],
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        style: TextStyle(color: theme.colorScheme.error),
                        textAlign: TextAlign.center),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : (widget.setup ? _create : _unlock),
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    child: _busy
                        ? const SizedBox(
                            height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                        : Text(widget.setup ? 'Create vault' : 'Unlock'),
                  ),
                  if (widget.setup) ...[
                    const SizedBox(height: 24),
                    const Divider(),
                    TextButton.icon(
                      icon: const Icon(Icons.settings_backup_restore),
                      label: const Text('Restore from a backup file'),
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                                final messenger = ScaffoldMessenger.of(context);
                                final ok = await app.restoreFromBackup(intoDir: _dir);
                                if (ok) {
                                  messenger.showSnackBar(const SnackBar(
                                      content: Text('Backup restored. Enter its passcode.')));
                                }
                              }),
                    ),
                    if (!Native.isAndroid)
                      TextButton.icon(
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Open an existing vault folder'),
                        onPressed: _busy
                            ? null
                            : () async {
                                final d = await Native.pickFolder(title: 'Choose a vault folder');
                                if (d == null) return;
                                final ok = await app.useExistingVault(d);
                                if (!ok) setState(() => _error = 'No Lockbox vault in that folder.');
                              },
                      ),
                    const TaskBanner(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Rough passcode strength: (0..1, label, colour).
  (double, String, Color) _strength(String p) {
    var pool = 0;
    if (RegExp('[a-z]').hasMatch(p)) pool += 26;
    if (RegExp('[A-Z]').hasMatch(p)) pool += 26;
    if (RegExp('[0-9]').hasMatch(p)) pool += 10;
    if (RegExp('[^a-zA-Z0-9]').hasMatch(p)) pool += 32;
    var bits = 0.0;
    if (pool > 0) {
      var x = pool.toDouble();
      var log2 = 0.0;
      while (x > 1) {
        x /= 2;
        log2 += 1;
      }
      bits = p.length * log2;
    }
    if (p.isEmpty) return (0, 'Tip: a few random words make a strong, memorable passcode.', Colors.grey);
    if (bits < 40) return (0.25, 'Weak – easy to guess if someone gets a copy of your backup', Colors.red);
    if (bits < 60) return (0.5, 'Fair', Colors.orange);
    if (bits < 80) return (0.75, 'Good', Colors.lightGreen);
    return (1, 'Strong', Colors.green);
  }
}
