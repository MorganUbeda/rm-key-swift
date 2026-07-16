# rm-key

Type into a **reMarkable Paper Pro** from your Mac.

`rm-key` is a small native macOS menu-bar app for people who use their reMarkable as a dedicated note-taking surface during calls, meetings, or focused work. The original use case was: keep Zoom/Meet/Teams on the Mac, keep notes open on the Paper Pro, and type into the tablet without switching to the reMarkable desktop app or attaching a Type Folio.

> [!WARNING]
> This is an experimental hacker tool for reMarkable Paper Pro power users. It requires Developer Mode, root SSH access, and temporarily restarts `xochitl` on the tablet. It is not affiliated with, endorsed by, or supported by reMarkable.

## What it does

- Captures text typed into a small floating macOS HUD.
- Sends UTF-8 text and navigation keys to the tablet over SSH.
- Select/copy/paste editing shortcuts are designed and hardware-validated; the
  production editing-command protocol is still being integrated.
- Injects synthetic Qt key events directly into the focused `xochitl` text object.
- Supports accented/international characters because it sends Unicode text, not keyboard-layout-dependent keycodes.
- Uses a temporary tablet-side injector; a tablet reboot clears it.

```text
Mac rm-key app
  └─ SSH tunnel / libssh2
      └─ 127.0.0.1:31338 on the tablet
          └─ librmkey_qt_inject.so loaded into xochitl
              └─ text: QKeyEvent → focusObject()
                 editing: qt_handleKeyEvent(focusWindow(), ...)
```

## Compatibility

Tested/targeted setup:

- reMarkable Paper Pro
- macOS 14+
- Swift 5.9+
- USB SSH at `10.11.99.1`

This project is **not currently intended for reMarkable 1 or reMarkable 2**. It depends on Paper Pro Developer Mode and the Paper Pro `xochitl`/Qt runtime.

Firmware updates may break the injector. If that happens, please open an issue with your tablet OS version and logs.

## Safety notes

Before using this, understand the tradeoffs:

- Paper Pro SSH access requires **Developer Mode**.
- Enabling Developer Mode may factory-reset the tablet; sync/back up first.
- Developer Mode weakens the tablet's security model and shows a boot warning.
- The app stores the tablet IP and root password in the macOS Keychain.
- The app uploads an ARM64 Linux shared library to `/tmp` on the tablet.
- The app installs a temporary systemd drop-in under `/run/systemd/system/xochitl.service.d/` and restarts `xochitl.service`.
- Everything is intended to be temporary: rebooting the tablet removes the injector/drop-in.

If you are not comfortable with root SSH or Developer Mode, do not use this.

Official reMarkable Developer Mode documentation: <https://developer.remarkable.com/documentation/developer-mode>

## Requirements

### Mac

- macOS 14+
- Xcode Command Line Tools / Swift toolchain
- Homebrew `libssh2`
- Nix, for cross-compiling the tablet injector

```sh
brew install libssh2
```

### Tablet

- reMarkable Paper Pro with Developer Mode enabled
- Root SSH password from the tablet settings
- USB networking, usually available at `10.11.99.1`

## Build from source

### 1. Fetch Paper Pro Qt libraries

The injector links against Qt libraries that already exist on the tablet. Fetch them into the ignored local sysroot:

```sh
./scripts/fetch-qt-libs.sh 10.11.99.1
```

Equivalent manual commands:

```sh
mkdir -p tablet-sysroot/usr/lib
scp root@10.11.99.1:/usr/lib/libQt6Core.so\* tablet-sysroot/usr/lib/
scp root@10.11.99.1:/usr/lib/libQt6Gui.so\* tablet-sysroot/usr/lib/
```

`tablet-sysroot/` is intentionally git-ignored. It contains libraries copied from your own tablet for local linking only. Do **not** commit or redistribute `tablet-sysroot/` or files copied from reMarkable firmware.

### 2. Build the tablet injector

```sh
nix-build build-injector.nix
# output: result/librmkey_qt_inject.so
```

### 3. Bundle the injector into the macOS app resources

```sh
cp result/librmkey_qt_inject.so Sources/RMKeyApp/Resources/
```

`Sources/RMKeyApp/Resources/*.so` is also git-ignored. The injector binary is generated locally from source and should not be committed to the source repo.

### 4. Build and run the Mac app

```sh
swift build -c release
swift run -c release
```

The app appears as a keyboard icon in the macOS menu bar.

## Usage

1. Enable Developer Mode on the Paper Pro and get the root SSH password from the tablet settings.
2. Connect the tablet by USB.
3. Launch `rm-key`.
4. Open **Settings...** from the menu-bar icon.
5. Enter the tablet IP, usually `10.11.99.1`, and root password.
6. Click **Upload Daemon**.
   - This uploads `/tmp/librmkey_qt_inject.so`.
   - It installs a temporary systemd drop-in for `xochitl.service`.
   - It restarts `xochitl` and waits for the injector to listen on tablet localhost port `31338`.
7. Click **Start Capture**.
8. Click into the small Capture window and type.

Supported navigation/control keys:

```text
Backspace
Delete
Enter
Left / Right / Up / Down
Tab
Escape
Home / End
```

Text to sanity-check Unicode input:

```text
hello world
é è ê ë ñ ç ö ü
Café déjà vu naïve façade
```

Expected behavior:

- text appears once in the focused tablet text object
- accented characters appear correctly
- the virtual keyboard does not open
- a tablet reboot removes the temporary injector

## Privacy

`rm-key` does not use cloud services, analytics, telemetry, or third-party servers. It connects directly from your Mac to your tablet over SSH.

Stored credentials:

- Service: `rm-key`
- Accounts: `ip` and `root`
- Storage: macOS Keychain

To remove saved credentials manually:

```sh
security delete-generic-password -s rm-key -a ip 2>/dev/null || true
security delete-generic-password -s rm-key -a root 2>/dev/null || true
```

## Troubleshooting

### Injector connection refused

Run **Upload Daemon** again. The injector only listens after `xochitl` has restarted with `LD_PRELOAD`.

### `Upload Daemon` fails

Check that:

- Developer Mode is enabled.
- The tablet is connected by USB.
- `ssh root@10.11.99.1` works in Terminal.
- `Sources/RMKeyApp/Resources/librmkey_qt_inject.so` exists.

### xochitl does not start

The drop-in is temporary, but you can remove it manually over SSH:

```sh
rm -f /run/systemd/system/xochitl.service.d/rm-key.conf
systemctl daemon-reload
systemctl restart xochitl.service
```

Logs:

```sh
journalctl -u xochitl.service -n 80 --no-pager
cat /tmp/rmkey-qt-inject.log
```

### Text duplicates

Printable text is sent only to `QGuiApplication::focusObject()`; sending it to
both the focus object and window duplicates insertion. Editing commands use the
separate `qt_handleKeyEvent(focusWindow(), ...)` route. If text duplicates after
a firmware update, please open an issue.

## Project structure

```text
Sources/RMKeyApp/          macOS SwiftUI menu-bar app
Sources/RMKeyApp/Core/     SSH, deployment, protocol, keychain
Sources/RMKeyApp/Capture/  floating capture window
Sources/RMKeyApp/Resources bundled injector .so, generated locally
daemon/                    C++ Qt injector for xochitl
build-injector.nix         aarch64 cross-compile derivation
docs/DESIGN.md             architecture notes
```

## Development notes

- Swift dependencies are managed with SwiftPM.
- The SSH client currently uses `libssh2` via a small SwiftPM system-library target.
- The injector is C++ and is cross-compiled to aarch64 Linux with Nix.
- Format Swift code before submitting changes:

```sh
swift-format --in-place --recursive Sources/
```

## Status

This is a weekend project built to solve a specific personal workflow. Contributions and bug reports are welcome, but support is best-effort.

## License

MIT. See [`LICENSE`](LICENSE).

For dependency and binary-distribution notices, see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Disclaimer

Not affiliated with reMarkable AS. Use at your own risk. You are responsible for any changes you make to your tablet.
