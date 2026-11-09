import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../platform/native.dart';
import '../state/app_state.dart';
import 'common.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const _lockOptions = <int, String>{
    0: 'Immediately',
    30: 'After 30 seconds',
    60: 'After 1 minute',
    300: 'After 5 minutes',
    900: 'After 15 minutes',
  };

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (!app.isUnlocked) return const SizedBox.shrink();
    final s = app.settings;
    final theme = Theme.of(context);
    Widget section(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
          child: Text(t, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Column(children: [
        const TaskBanner(),
        Expanded(
          child: ListView(children: [
            section('Security'),
            ListTile(
              leading: const Icon(Icons.password),
              title: const Text('Change passcode'),
              subtitle: const Text('Instant – files don\'t need re-encrypting'),
              onTap: () => _changePasscode(context),
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('Auto-lock'),
              subtitle: Text(_lockOptions[s.autoLockSeconds] ?? '${s.autoLockSeconds} s'),
              onTap: () async {
                final v = await showDialog<int>(
                  context: context,
                  builder: (ctx) => SimpleDialog(
                    title: const Text('Lock when Lockbox is in the background'),
                    children: [
                      for (final e in _lockOptions.entries)
                        SimpleDialogOption(
                          onPressed: () => Navigator.pop(ctx, e.key),
                          child: Row(children: [
                            Icon(e.key == s.autoLockSeconds ? Icons.radio_button_checked : Icons.radio_button_off),
                            const SizedBox(width: 12),
                            Text(e.value),
                          ]),
                        ),
                    ],
                  ),
                );
                if (v != null) await app.updateSettings((x) => x.autoLockSeconds = v);
              },
            ),
            const ListTile(
              leading: Icon(Icons.screenshot_monitor),
              title: Text('Screenshots & sharing are blocked'),
              subtitle: Text('Lockbox can\'t be screenshotted, screen-recorded or shared. '
                  'Use “Save frame” on a paused video to keep a still inside Lockbox.'),
            ),

            section('Adding files'),
            SwitchListTile(
              secondary: const Icon(Icons.drive_file_move_outline),
              title: const Text('Move files into Lockbox'),
              subtitle: const Text('Delete the unprotected originals after adding (default choice)'),
              value: s.deleteOriginalsOnImport,
              onChanged: (v) => app.updateSettings((x) => x.deleteOriginalsOnImport = v),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.sell_outlined),
              title: const Text('Tag from file names'),
              subtitle: const Text('Each word in a file name becomes a tag (numbers are ignored)'),
              value: s.autoTagFromNames,
              onChanged: (v) => app.updateSettings((x) => x.autoTagFromNames = v),
            ),

            section('Restoring files'),
            ListTile(
              leading: const Icon(Icons.folder_special_outlined),
              title: const Text('Default restore folder'),
              subtitle: Text(app.defaultRestoreLabel),
              trailing: s.restoreFolder == null
                  ? null
                  : IconButton(
                      tooltip: 'Use built-in default',
                      icon: const Icon(Icons.clear),
                      onPressed: app.clearDefaultRestoreFolder,
                    ),
              onTap: app.chooseDefaultRestoreFolder,
            ),
            SwitchListTile(
              secondary: const Icon(Icons.copy_all_outlined),
              title: const Text('Keep a copy in Lockbox when restoring'),
              subtitle: const Text('Default choice in the restore dialog'),
              value: s.keepCopyOnRestore,
              onChanged: (v) => app.updateSettings((x) => x.keepCopyOnRestore = v),
            ),

            section('Playback'),
            SwitchListTile(
              secondary: const Icon(Icons.repeat),
              title: const Text('Loop videos'),
              value: s.loopVideos,
              onChanged: (v) => app.updateSettings((x) => x.loopVideos = v),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.volume_off_outlined),
              title: const Text('Start videos muted'),
              value: s.muteByDefault,
              onChanged: (v) => app.updateSettings((x) => x.muteByDefault = v),
            ),

            section('Backup'),
            ListTile(
              leading: const Icon(Icons.backup_outlined),
              title: const Text('Back up vault to a file'),
              subtitle: const Text(
                  'Saves everything as one encrypted .lockbox file. It can only be opened '
                  'with Lockbox and your passcode.'),
              onTap: () async {
                try {
                  final ok = await app.backUp();
                  if (ok && context.mounted) snack(context, 'Backup saved');
                } catch (e) {
                  if (context.mounted) snack(context, 'Backup failed: $e');
                }
              },
            ),
            const ListTile(
              leading: Icon(Icons.settings_backup_restore),
              title: Text('Restoring a backup'),
              subtitle: Text('Install Lockbox on the new device and choose '
                  '“Restore from a backup file” on the first screen.'),
            ),
            if (!Native.isAndroid)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('Vault folder'),
                subtitle: Text('${app.vaultDir}\nYou can also back up by copying this whole folder.'),
                isThreeLine: true,
              ),

            section('About'),
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('Version'),
              subtitle: Text(String.fromEnvironment('LOCKBOX_VERSION', defaultValue: 'development build')),
            ),
            const ListTile(
              leading: Icon(Icons.shield_outlined),
              title: Text('How your files are protected'),
              subtitle: Text(
                'Every file, thumbnail, name, date and tag is encrypted with AES-256 on this device. '
                'Your passcode is turned into the key with Argon2id, which makes guessing slow. '
                'Lockbox has no internet access and no accounts – nobody, including the '
                'developer, can recover a forgotten passcode.'),
            ),
            const SizedBox(height: 32),
          ]),
        ),
      ]),
    );
  }

  Future<void> _changePasscode(BuildContext context) async {
    final app = context.read<AppState>();
    final cur = TextEditingController();
    final next = TextEditingController();
    final again = TextEditingController();
    String? error;
    var busy = false;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Change passcode'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: cur, obscureText: true, decoration: const InputDecoration(labelText: 'Current passcode')),
            TextField(controller: next, obscureText: true, decoration: const InputDecoration(labelText: 'New passcode')),
            TextField(controller: again, obscureText: true, decoration: const InputDecoration(labelText: 'Repeat new passcode')),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(error!, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              ),
          ]),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (next.text.length < 8) return setS(() => error = 'Use at least 8 characters.');
                      if (next.text != again.text) return setS(() => error = 'New passcodes don\'t match.');
                      setS(() {
                        busy = true;
                        error = null;
                      });
                      final ok = await app.changePassphrase(cur.text, next.text);
                      if (!ctx.mounted) return;
                      if (!ok) {
                        return setS(() {
                          busy = false;
                          error = 'Current passcode is wrong.';
                        });
                      }
                      Navigator.pop(ctx);
                      if (context.mounted) {
                        snack(context, 'Passcode changed. Old backups still use the old passcode.');
                      }
                    },
              child: busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Change'),
            ),
          ],
        ),
      ),
    );
  }
}
