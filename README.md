# rm-key

Type into a **reMarkable Paper Pro** from your Mac.

`rm-key` is a small native macOS app that lets you type into your RMPP directly from your Mac's keyboard. A small capture window floats above the rest of your windows and follows you around spaces. When focused everything that is typed in the window is sent to the reMarkable.

The reMarkable becomes a dedicated note-taking surface during calls, meetings, or focused work. The original use case was to keep Zoom/Meet/Teams on the Mac, keep notes open on the Paper Pro, and type into the tablet without switching to the reMarkable desktop app and without leaving the Mac keyboard. Now it became my main note taking tool, allowing me to use the RMPP as a dedicated note-taking second screen that I keep on a little vertical stand on my desk. I always have the little capture window open somewhere on a corner of my screen, and Cmd+Tab into it to take typed notes.

## Principle

- The app uploads an ARM64 Linux shared library to `/tmp` on the tablet.
- The app installs a temporary systemd drop-in under `/run/systemd/system/xochitl.service.d/` and restarts `xochitl.service`.
- Everything is intended to be temporary: rebooting the tablet removes the injector/drop-in.

> [!WARNING]
> This is an experimental tool. It requires Developer Mode and root SSH access. It is not affiliated with, endorsed by, or supported by reMarkable. Even though the daemon and patch are temporary and should not persist across reboots, I am not responsible for damages to your tablet.

Official reMarkable Developer Mode documentation: <https://developer.remarkable.com/documentation/developer-mode>

## Features and roadmap

The text injection and basic shortcuts are all implemented and working.

- [x] Insert text in quick notes / notebooks / text fields (e.g. note name)
- [x] Keyboard shortcuts for editing
  - [x] Shift + Arrow for selection
  - [x] ⌘C, ⌘X, ⌘V for copy/cut/paste
  - [x] ⌘A for select all
  - [x] ⌘Z for undo
- [x] full accented/international characters support by directly sending Unicode text
- [ ] Keyboard navigation in notebooks
  - [x] Arrow keys for navigation within the text
  - [ ] Shortcuts to navigate between pages
  - [ ] Shortcut to open the page selection menu in a notebook
  - [ ] Move pages around using keyboard shortcuts once in the page screen
- [ ] Navigation support outside of notebooks
  - [x] Escape to exit notebook
  - [x] Arrow keys to navigate UI elements
  - [ ] Backspace to go back one level in the file explorer
  - [ ] Copy/Cut/Paste files in the file manager with keyboard shortcuts

## Compatibility

Targeted setup:

- reMarkable Paper Pro with developer mode enabled
- macOS 14+
- Swift 5.9+

This project is **not currently intended for reMarkable 1 or reMarkable 2**. It depends on Paper Pro Developer Mode and the Paper Pro `xochitl`/Qt runtime.

Firmware updates may break the injector. If that happens, please open an issue with your tablet OS version and logs.

## Requirements for building the tool

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
- USB networking or SSH over wifi

## Build from source

### 1. Fetch Paper Pro Qt libraries

The injector links against Qt libraries that already exist on the tablet. Fetch them into the local sysroot folder:

```sh
./scripts/fetch-qt-libs.sh 10.11.99.1
```

Equivalent manual commands:

```sh
mkdir -p tablet-sysroot/usr/lib
scp root@10.11.99.1:/usr/lib/libQt6Core.so\* tablet-sysroot/usr/lib/
scp root@10.11.99.1:/usr/lib/libQt6Gui.so\* tablet-sysroot/usr/lib/
```

### 2. Build the tablet injector

```sh
nix-build build-injector.nix
# output: result/librmkey_qt_inject.so
```

### 3. Bundle the injector into the macOS app resources

```sh
cp result/librmkey_qt_inject.so Sources/RMKeyApp/Resources/
```

### 4. Build and run the Mac app

```sh
swift build -c release
swift run -c release
```

The app appears as a keyboard icon in the macOS menu bar.

## Usage

1. Enable Developer Mode on the Paper Pro and get the root SSH password from the tablet settings.
2. Connect the tablet by USB (or connect to the same wifi network if SSH over wifi is enabled).
3. Launch `rm-key`.
4. Open **Settings...** from the menu-bar icon.
5. Enter the tablet IP (usually `10.11.99.1` over USB, see the [Developer Mode docs](https://developer.remarkable.com/documentation/developer-mode) for the correct address) and root password.
6. Click **Upload Daemon**.
   - This uploads `/tmp/librmkey_qt_inject.so`.
   - It installs a temporary systemd drop-in for `xochitl.service`.
   - It restarts `xochitl`.
7. Click **Start Capture**.
8. Click into the small Capture window and type.

Capture stops when the window loses focus. Click back into it to resume.

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

Editing shortcuts (tablet clipboard):

```text
⌘C   Copy
⌘V   Paste
⌘X   Cut
⌘A   Select All
⌘Z   Undo
⇧←  Shift-select left
⇧→  Shift-select right
⇧↑  Shift-select up
⇧↓  Shift-select down
⌘⇧←  Shift-select to start of line
⌘⇧→  Shift-select to end of line
```

## Privacy

`rm-key` does not use cloud services, analytics, telemetry, or third-party servers. It connects directly from your Mac to your tablet over SSH.

Credentials are stored locally in the macOS keychain:

- Service: `rm-key`
- Username: `root`
- Tablet IP: stored as `ip`

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
- The tablet is connected by USB or on the same wifi network, and the IP address is properly configured on the app settings
- `ssh root@<ip-address>` works in Terminal.
- `Sources/RMKeyApp/Resources/librmkey_qt_inject.so` exists.

### xochitl does not start

The drop-in is temporary and should disappear after restarting the tablet, but you can remove it manually over SSH:

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

## Project structure

```text
Sources/RMKeyApp/          macOS SwiftUI menu-bar app
Sources/RMKeyApp/Core/     SSH, deployment, protocol, keychain
Sources/RMKeyApp/Capture/  floating capture window
Sources/RMKeyApp/Resources/   bundled injector .so, generated locally
daemon/                    C++ Qt injector for xochitl
scripts/                   Fetch Qt libraries from tablet
build-injector.nix         aarch64 cross-compile derivation
docs/DESIGN.md             architecture notes
```

## Development notes

- Swift system libraries (libssh2) are linked via SwiftPM targets.
- The SSH client currently uses `libssh2` via a small SwiftPM system-library target.
- The injector is C++ and is cross-compiled to aarch64 Linux with Nix.

## Status

This is a weekend project built to solve a specific personal workflow. Contributions and bug reports are welcome, but support is best-effort. The whole thing is 99.9\% vibe-coded.

## License

MIT. See [`LICENSE`](LICENSE).

For dependency and binary-distribution notices, see [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Disclaimer

Not affiliated with reMarkable AS. Use at your own risk. You are responsible for any changes you make to your tablet.
