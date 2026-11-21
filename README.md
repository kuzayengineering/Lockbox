# Lockbox

A private, encrypted vault for photos, videos, audio **and any other files**
(documents, PDFs, spreadsheets, archives…), for **Android** and **Windows**, with
Google Photos–style viewing and playback built in.

Nothing leaves your device. The Android app has no internet permission, and
there are no accounts or cloud servers.

## Features

**Privacy**
- Every file, thumbnail, file name, date, tag and folder is encrypted with
  AES-256 on the device.
- Your passcode is turned into the encryption key with Argon2id, which makes
  guessing passcodes slow and expensive.
- Screenshots, screen recording, screen sharing and the recent-apps preview are
  always blocked on Android. On Windows the window is excluded from screen
  capture.
- There is no share button. The only way out of the vault is **Restore**.
- Auto-lock when the app is in the background (immediately, or after 30 s,
  1, 5 or 15 min).

**Library**
- Folders (including folders inside folders) and tags.
- Tags are created automatically from the words in a file's name. Numbers are
  ignored, so `Beach trip with Sam 2024.mp4` is tagged *Beach, trip, with, Sam*.
- Sort by date taken, date added, length, file size, name or resolution.
- Filters that combine: type, tags (any or all), untagged, favourites,
  HDR/HLG/Dolby Vision, 60 fps or more, length, file size, and date range.
- Search across names, tags and notes.
- Photo grid grouped by day or month. Pinch to change the grid size.
- **View** button: Grid or Details (thumbnail with name, tags and details
  beside it), and choose what's shown: file name, length, frame rate, tags,
  file size, date taken, HDR badge. In the grid, names and tags appear on the
  thumbnails at 3 or fewer per row.
- Views are remembered **per folder**: changing the view inside a folder saves
  it for that folder only; changing it in Library sets the default (also in
  *Settings › Default view*).

**Playback (Google Photos style)**
- Swipe left and right between items. Swipe down to close, swipe up for info.
- Photos: pinch or double-tap to zoom.
- Videos play automatically, with a scrub bar, play/pause, ±10 s on double-tap
  at the sides, **previous/next frame** buttons, speed control from 0.25× to 2×,
  loop and mute.
- **HDR10, HLG and Dolby Vision** play in true HDR on Android at full frame
  rate (60 fps and higher) using Android's own ExoPlayer and the phone's
  hardware decoders.
- **Save frame**: pause a video and tap the camera button. The frame is saved
  as a photo in the *Screenshots* folder inside Lockbox, dated like the source
  video and given the same tags.
- Windows keyboard shortcuts: ← → next/previous item, Space play/pause,
  `,` `.` previous/next frame, F favourite, Esc close.

**Documents and other files**
- Any kind of file can be stored, with the same encryption, folders, tags,
  sorting, filters, search, restore and backup.
- PDFs get a first-page thumbnail. PDFs and text files (txt, csv, json, log…)
  open in a reader inside Lockbox; the file is decrypted in memory only, and
  text can't be selected or copied out.
- Other types (Word, Excel, zip…) can't be shown inside Lockbox. Use
  **Restore** to put a copy back on the device and open it with another app.

**Adding and restoring**
- **Move** files into Lockbox (the originals are deleted) or **Copy** them.
- **Restore** puts an unencrypted copy back on the device: to the **original
  location**, to the **default restore folder** chosen in Settings, or to any
  folder you choose. You can keep a copy in Lockbox or remove it.
- On Android, restoring decrypts straight into the destination, so no
  temporary unencrypted copy is ever written.

**Backup**
- *Settings › Back up vault to a file* writes the whole vault as one
  `.lockbox` file. It is encrypted and can only be opened with Lockbox and your
  passcode.
- To restore, install Lockbox on the new device and tap *Restore from a backup
  file* on the first screen.
- On Windows you can also back up by copying the vault folder.

## Getting the app

Each update to the `main` branch is built automatically and published as a
numbered release (Lockbox 1.0.1, 1.0.2, …) on the repository's **Releases**
page. The five newest are kept:

- `Lockbox-android.apk`: install on the phone (allow "install unknown apps"
  for your browser or file manager when asked).
- `Lockbox-windows.zip`: unzip anywhere and run `lockbox.exe`.

### Automatic updates on Android (Obtainium)

Lockbox itself has no internet access, so it can't check for updates. The
free app [Obtainium](https://github.com/ImranR98/Obtainium) does it instead:
it watches this repository's releases (using a read-only GitHub token stored
in Obtainium, not in Lockbox), notifies you of new versions and installs them.
The installed version is shown in Lockbox under *Settings › About*.

### Android signing key (already set up)

Android only installs an update over an existing app if both were signed with
the same key, and uninstalling the app deletes the vault on the phone. The
permanent key is stored as two encrypted repository secrets
(`ANDROID_KEYSTORE_BASE64` and `ANDROID_KEY_PASSWORD`, under *Settings ›
Secrets and variables › Actions*); they stay private even if the repository is
public. Keep the backup copy of the key file and its password somewhere safe
(e.g. a password manager): if the secrets are ever lost, add them again from
that copy. Without them the build produces a `Lockbox-android-TEST-ONLY.apk`.

## How it works

| Piece | Technology |
|---|---|
| App (both platforms) | Flutter / Dart |
| Encryption | AES-256-GCM through BoringSSL (`webcrypto`), Argon2id key derivation |
| Android playback | Media3 ExoPlayer in a native SurfaceView (true HDR); decrypts inside the player |
| Windows playback | libmpv (`media_kit`), fed by a private loopback stream with a random token, bound to 127.0.0.1 only |
| Metadata | Built-in MP4/MOV reader (length, fps, HDR from the container *or* the HEVC stream), EXIF dates, Android MediaMetadataRetriever |

### Vault layout

```
Lockbox Vault/
  index.lbx        encrypted library: items, folders, tags, settings
  index.lbx.bak    previous copy of the index, used automatically if the main one is damaged
  blobs/ab/<id>    encrypted originals
  thumbs/ab/<id>   encrypted thumbnails
```

File names are random. Without the passcode, nothing about the contents can be
seen except how many files there are and roughly how large they are.

Each file is encrypted in 256 KB chunks, each with its own authentication
tag. Any part of a video can be decrypted on its own, so seeking is instant,
and any tampering or corruption is detected. Each file has its own random key,
which is protected by the vault's master key. The master key is protected by
your passcode, so changing the passcode is instant.

### Security notes

- **Choose a strong passcode.** Someone who copies your backup file can try to
  guess the passcode offline. Argon2id makes each guess slow, but a short PIN
  can still be guessed. A few random words work well.
- A forgotten passcode cannot be recovered by anyone.
- On Windows, HDR video is shown tone-mapped (correct colours, standard
  brightness). Windows apps built with Flutter can't output true HDR yet.

## For developers

```bash
flutter pub get
dart run webcrypto:setup   # once, so the tests can use the crypto library
flutter test
flutter run                # on a connected Android phone or on Windows
```

The core (`lib/core/`) contains no Flutter UI code and is covered by
`test/core_test.dart`. The encrypted file format is documented at the top of
`lib/core/blob_format.dart`. The Kotlin reader in
`android/app/src/main/kotlin/.../EncryptedBlobDataSource.kt` must stay in sync
with it.
