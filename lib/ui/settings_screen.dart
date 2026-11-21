import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../platform/native.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'view_sheet.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});


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
            section('General'),
            ListTile(
              leading: const Icon(Icons.home_outlined),
              title: const Text('Start screen'),
              subtitle: Text(_startLabel(app)),
              onTap: () async {
                final (ok, id) = await pickFolder(context, title: 'Open after unlocking');
                if (ok) await app.updateSettings((x) => x.startFolderId = id);
              },
            ),
            ListTile(
              leading: const Icon(Icons.grid_view_outlined),
              title: const Text('Default view'),
              subtitle: Text(describeView(s.defaultView)),
              onTap: () => showViewSheet(context, defaultOnly: true),
            ),

            section('Security'),
            ListTile(
              leading: const Icon(Icons.password),
              title: const Text('Change passcode'),
              subtitle: const Text('Instant – files don\'t need re-encrypting'),
              onTap: () => _changePasscode(context),
            ),
            const ListTile(
              leading: Icon(Icons.timer_outlined),
              title: Text('Locks immediately'),
              subtitle: Text('Lockbox locks as soon as you leave it: home button, '
                  'recent apps, switching apps, or the screen turning off.'),
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
              subtitle: const Text('Starting choice for “Add tags from file names” when adding files'),
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
              secondary: const Icon(Icons.sell_outlined),
              title: const Text('Keep tags in restored photos and videos'),
              subtitle: const Text('Writes the tags into the file (JPEG, HEIC, MP4, MOV) so they '
                  'come back if you add it to Lockbox again. Other apps can see these tags.'),
              value: s.tagsInFiles,
              onChanged: (v) => app.updateSettings((x) => x.tagsInFiles = v),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.copy_all_outlined),
              title: const Text('Keep a copy in Lockbox when restoring'),
              subtitle: const Text('Default choice in the restore dialog'),
              value: s.keepCopyOnRestore,
              onChanged: (v) => app.updateSettings((x) => x.keepCopyOnRestore = v),
            ),

            section('Playback'),
            if (Native.isAndroid)
              SwitchListTile(
                secondary: const Icon(Icons.hdr_on),
                title: const Text('Save frames of HDR videos as HDR HEIF'),
                subtitle: Text(s.saveFramesAsHeif
                    ? '10-bit HEIF with the video\'s own HDR picture (.heic)'
                    : 'Normal JPEG photo (Android\'s own conversion)'),
                value: s.saveFramesAsHeif,
                onChanged: (v) => app.updateSettings((x) => x.saveFramesAsHeif = v),
              ),
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

  static String _startLabel(AppState app) {
    final id = app.settings.startFolderId;
    if (id == null) return 'Library';
    final f = app.foldersById[id];
    return f == null ? 'Library (the chosen folder was deleted)' : 'Folder: ${f.name}';
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
