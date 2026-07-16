# rm-key — Design Document

Send text and editing keys from a Mac to a reMarkable Paper Pro over SSH.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  macOS 14+                                                  │
│                                                             │
│  rm-key (Swift, native)                                     │
│                                                             │
│  ┌─────────────────────┐   ┌──────────────────────────┐    │
│  │  MenuBarExtra        │   │  Settings Window         │    │
│  │  ─────────────────   │   │  ─────────────────────   │    │
│  │  ● Status dot        │   │  IP address field        │    │
│  │  Start/Stop Capture  │   │  Password field          │    │
│  │  Upload Daemon       │   │  Save credentials        │    │
│  │  Settings...         │   │  Upload Daemon           │    │
│  │  Quit                │   └──────────┬───────────────┘    │
│  └──────────┬───────────┘              │                    │
│             │                          │                    │
│  ┌──────────┴──────────────────────────┴──────────────┐    │
│  │  AppState (@Observable, shared source of truth)    │    │
│  └──────────────────────┬─────────────────────────────┘    │
│                         │                                   │
│  ┌──────────────────────┴─────────────────────────────┐    │
│  │  Capture HUD Window (.canJoinAllSpaces, .floating)  │    │
│  │  ────────────────────────────────────────────────   │    │
│  │  NSTextField delegate + local shortcut monitor       │    │
│  │  → FramedProtocol                                    │    │
│  │  Frontmost while user types in the HUD               │    │
│  └──────────────────────┬─────────────────────────────┘    │
│                         │                                   │
│  ┌──────────────────────┴─────────────────────────────┐    │
│  │  SSHActor (actor, serialized state)                │    │
│  │  ────────────────────────────────────────────────   │    │
│  │  libssh2 persistent connection                      │    │
│  │  • Password auth                                    │    │
│  │  • direct-tcpip → 127.0.0.1:31338                   │    │
│  │  • exec channels → commands, file upload            │    │
│  └──────────────────────┬─────────────────────────────┘    │
│                         │                                   │
│  ┌──────────────────────┴─────────────────────────────┐    │
│  │  Deployer                                          │    │
│  │  Upload injector .so, install systemd drop-in,     │    │
│  │  restart xochitl, poll injector port               │    │
│  └──────────────────────┬─────────────────────────────┘    │
│                         │                                   │
│  ┌──────────────────────┴─────────────────────────────┐    │
│  │  CredentialStore (Keychain via Security.framework)  │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                             │
└──────────────────────────┬──────────────────────────────────┘
                           │ SSH :22
                           ▼
              ┌────────────────────────────────┐
              │  reMarkable Paper Pro           │
              │                                │
              │  xochitl (Qt/QML UI)            │
              │  launched with LD_PRELOAD       │
              │                                │
              │  ┌──────────────────────────┐  │
              │  │ librmkey_qt_inject.so    │  │
              │  │ listens 127.0.0.1:31338 │  │
              │  │ sends Qt QKeyEvent      │  │
              │  │ to focusObject()        │  │
              │  └──────────────────────────┘  │
              └────────────────────────────────┘
```

The client sends semantic UTF-8 text, named control keys, and semantic editing
commands. On the tablet, an LD_PRELOAD helper loaded into xochitl receives
those frames and injects synthetic Qt key events into xochitl's current focus
path. Printable text continues to use the focus object directly; editing
commands use Qt's normal `qt_handleKeyEvent(focusWindow(), ...)` route.

---

## Protocol Choice: Qt Injector Instead of uinput

The first implementation used a standalone C daemon with `/dev/uinput`. That worked for basic US-QWERTY keycodes but could not reliably input accented characters. Tests showed that xochitl on the Paper Pro does not accept dead-key composition, Compose sequences, or Ctrl+Shift+U Unicode input through the evdev/uinput path.

The working path is higher-level: create a `QKeyEvent` inside xochitl with the desired Unicode text in the event's `text()` field, and send it to `QGuiApplication::focusObject()`. This inserts text without opening the virtual keyboard and without relying on keyboard layout.

Confirmed behavior:

- Synthetic Qt `QKeyEvent` with `Qt::Key_unknown` and Unicode `text()` inserts printable UTF-8 text.
- Sending the event only to `QGuiApplication::focusObject()` inserts once.
- Sending to both focus object and focus window duplicates text.
- `QInputMethodEvent` works only when the virtual keyboard is open, so it is not used.
- The virtual keyboard is not opened by the final path.

---

## Tablet Component: `librmkey_qt_inject.so`

- **Target architecture:** `aarch64`
- **Loaded by:** temporary systemd drop-in for `xochitl.service` with `Environment=LD_PRELOAD=/tmp/librmkey_qt_inject.so`
- **Deployed to:** `/tmp/librmkey_qt_inject.so`
- **Listens:** `127.0.0.1:31338` inside the tablet network namespace
- **Accessed via:** SSH direct-tcpip channel from the Mac client
- **Runtime dependencies:** xochitl's existing Qt libraries, especially Qt Core and Qt Gui
- **No uinput dependency:** does not require `/dev/uinput` or `modprobe uinput`

The client is responsible for uploading the injector, installing a runtime systemd drop-in, and restarting xochitl with the preload:

```sh
mkdir -p /run/systemd/system/xochitl.service.d
cat >/run/systemd/system/xochitl.service.d/rm-key.conf <<'EOF'
[Service]
Environment=LD_PRELOAD=/tmp/librmkey_qt_inject.so
EOF
systemctl daemon-reload
systemctl restart xochitl.service
```

This is intentionally temporary. The injector lives in `/tmp` and the drop-in lives in `/run`; a reboot clears both.

---

## Wire Protocol

The SSH tunnel carries framed messages over a persistent TCP connection to `127.0.0.1:31338`.

Frame format:

| Offset | Size | Field | Description |
|--------|------|-------|-------------|
| 0 | 1 byte | type | `0x01` text, `0x02` control key, `0x03` editing command, `0x04` hello, `0x05` hello acknowledgement |
| 1–4 | 4 bytes | length | Payload length, little-endian unsigned integer |
| 5.. | length bytes | payload | UTF-8 text or ASCII control key name |

### Frame Types

#### `0x01` — UTF-8 text

Payload is UTF-8 text. The injector converts it to `QString` and sends:

```cpp
QKeyEvent press(QEvent::KeyPress, Qt::Key_unknown, Qt::NoModifier, text, false, 1);
QCoreApplication::sendEvent(QGuiApplication::focusObject(), &press);

QKeyEvent release(QEvent::KeyRelease, Qt::Key_unknown, Qt::NoModifier, QString(), false, 1);
QCoreApplication::sendEvent(QGuiApplication::focusObject(), &release);
```

#### `0x02` — control key

Payload is one ASCII control key name:

| Payload | Qt key |
|---------|--------|
| `BACKSPACE` | `Qt::Key_Backspace` |
| `DELETE` | `Qt::Key_Delete` |
| `ENTER` | `Qt::Key_Return` |
| `LEFT` | `Qt::Key_Left` |
| `RIGHT` | `Qt::Key_Right` |
| `UP` | `Qt::Key_Up` |
| `DOWN` | `Qt::Key_Down` |
| `TAB` | `Qt::Key_Tab` |
| `ESCAPE` | `Qt::Key_Escape` |
| `HOME` | `Qt::Key_Home` |
| `END` | `Qt::Key_End` |

Control keys are sent as Qt key press/release events with empty text.

#### `0x03` — editing command (feature extension)

The payload is one exact ASCII command name such as `COPY`, `PASTE`, or
`SHIFT_LEFT`. The injector maps the command to a Qt key/modifier pair and
calls `qt_handleKeyEvent(focusWindow(), ...)` so Qt shortcut processing is
preserved. The extension also defines `0x04` Hello and `0x05` Hello
acknowledgement. See `FEATURE_DESIGN.md` for the complete command mapping.

---

## Swift Client

### App Structure

The app runs as a menu bar accessory (no Dock icon, `.accessory` activation policy). Three views coordinate through a shared `@Observable AppState`:

| Window | Role |
|---|---|
| **MenuBarExtra** | Status dot, Start/Stop Capture, Upload Daemon, Settings gear, Quit |
| **Settings window** | IP address, root password, credential save, Upload Daemon button, transient status messages |
| **Capture HUD** | Floating window on all Spaces with a focused text field and local shortcut monitor |

### Activation Policy

The app uses `NSApp.setActivationPolicy(.accessory)` — no Dock icon, full window focus capability. This is the same pattern used by Alfred and 1Password mini.

### Capture Behavior

Key capture uses a focused AppKit `NSTextField` embedded in the SwiftUI Capture HUD. Printable text is read from `textDidChange`, sent as a UTF-8 text frame, then cleared locally so the field acts like a transient input buffer.

```
User types in Capture HUD
  → NSTextField/text view receives input
  → printable text: textDidChange → FramedProtocol.encodeText
  → unmodified controls: NSTextFieldDelegate.doCommandBy → encodeControl
  → editing shortcuts: local key-down monitor → encodeEditingCommand
  → ordered outbound sender → SSHActor.sendFrame()
```

This lets macOS input methods compose accented characters normally before the resulting Unicode text is sent to the tablet.

Unmodified controls are handled through AppKit command selectors such as
`deleteBackward:`, `moveLeft:`, `insertNewline:`, and `insertTab:`. Editing
shortcuts are intercepted by an app-local key-down monitor before AppKit key
equivalents run. Navigation events may include `.function` or `.numericPad`
flags; these are physical-key flags, not unsupported modifiers.

**Focus behavior:** The Capture HUD must be focused/frontmost. Switching to another app naturally stops capture because the text field no longer receives input.

### SSH Transport

The `SSHActor` wraps `libssh2` through a SwiftPM system-library target. It is an actor, serializing all SSH state mutations:

- **Connect:** Establish TCP connection, perform password authentication as `root`.
- **Injector channel:** Open a libssh2 direct-tcpip channel targeting `127.0.0.1:31338` on the tablet.
- **Commands:** Open exec channels for remote shell commands.
- **File upload:** Stream the injector `.so` through an exec channel running `cat > /tmp/librmkey_qt_inject.so.new`, then `mv` into place.
- **Reconnect:** If the SSH connection or injector channel drops, close and reconnect.

### Credentials

Stored in the macOS Keychain via `Security.framework` (`SecItemAdd`/`SecItemCopyMatching`/`SecItemDelete`). Service name: `rm-key`. Account: `root`. Stored values: IP address and password.

### Deployment Flow

The UI keeps the **Upload Daemon** label, but it uploads the Qt injector.

Upload action:

1. Read `librmkey_qt_inject.so` from the app bundle (`Bundle.main.resourceURL`).
2. SCP/stream the injector to `/tmp/librmkey_qt_inject.so.new` on the tablet via exec channel `cat`.
3. `chmod +x` and `mv` the staged file to `/tmp/librmkey_qt_inject.so`.
4. Install a runtime systemd drop-in that sets `LD_PRELOAD=/tmp/librmkey_qt_inject.so` for `xochitl.service`.
5. Run `systemctl daemon-reload`.
6. Stop any previous xochitl instance (`systemctl stop xochitl.service; killall xochitl || true`), then restart `xochitl.service` through systemd.
7. Poll for `127.0.0.1:31338` via a direct-tcpip channel (30s timeout, 2s interval).

The injector is intentionally not installed persistently.

---

## File Upload Mechanism

No SFTP is used. The file upload streams raw bytes through an exec channel running `cat > target_path`:

1. Open a libssh2 session channel.
2. Start an exec request for `cat > /tmp/librmkey_qt_inject.so.new`.
3. Write file bytes to the channel.
4. Send EOF to signal completion to `cat`.
5. Wait for exit status.

This is the same approach used by the Python client's exec-channel fallback path. It is reliable and works with any SSH server that supports exec channels (including Dropbear on the Paper Pro).

---

## Build Notes

### Swift Client

Built with SwiftPM:

```bash
swift build -c release
```

The resulting binary is at `.build/release/RMKeyApp`. For an `.app` bundle, wrap it manually or use an Xcode project generated from `Package.swift`.

### Injector (unchanged)

The injector is dynamically linked against Qt. The tablet already has the needed Qt runtime libraries, but the cross-link step needs matching aarch64 libraries available locally. The build tooling fetches these from the connected tablet into an ignored sysroot:

```sh
./scripts/fetch-qt-libs.sh 10.11.99.1
```

`tablet-sysroot/` is not committed. These libraries are firmware-specific vendor binaries.

---

## Project Structure

```
rm-key-macos/
├── Package.swift                       # SwiftPM manifest
├── Sources/
│   └── RMKeyApp/
│       ├── App.swift                   # @main entry, activation policy, scene setup
│       ├── AppState.swift              # @Observable: connection + capture state
│       ├── MenuBar/
│       │   └── MenuBarView.swift       # MenuBarExtra content
│       ├── Settings/
│       │   └── SettingsView.swift      # IP/password/upload window
│       ├── Capture/
│       │   └── CaptureWindow.swift     # HUD window + AppKit text field capture
│       ├── Core/
│       │   ├── SSHActor.swift          # SSH connection management (libssh2)
│       │   ├── FramedProtocol.swift    # Wire protocol encoder
│       │   ├── KeyMapper.swift         # ControlKey enum and legacy keyCode mapping
│       │   ├── Deployer.swift          # Injector upload + xochitl restart
│       │   └── CredentialStore.swift   # Keychain read/write
│       └── Resources/
│           └── librmkey_qt_inject.so   # Built by build-injector.nix
├── build-injector.nix                  # Nix derivation for Qt injector
├── daemon/
│   └── rmkey-qt-inject.cpp             # LD_PRELOAD Qt injector (unchanged)
└── docs/
    └── DESIGN.md
```

---

## Error Handling

| Situation | Handling |
|-----------|----------|
| Injector upload succeeds | Status shows upload success and waits for port `31338`. |
| xochitl fails to start | Status shows failure; logs are available via `journalctl -u xochitl.service`. |
| Injector port unavailable | Status shows failure to connect to injector. |
| SSH drops during capture | Close capture channel, reconnect SSH, reopen injector channel. |
| Tablet rebooted | Injector in `/tmp` is gone; user runs Upload Daemon again. |
| Invalid frame | Injector logs and skips the frame or closes the connection. |
| Unknown control key | Injector logs and ignores it. |
| App loses focus during capture | Capture pauses automatically; resumes on refocus. |

---

## Validation Matrix

Text:

```text
hello world
é è ê ë ñ ç ö ü
Café déjà vu naïve façade
```

Controls:

```text
Backspace
Delete
Enter
Left
Right
Up
Down
Tab
Escape
Home
End
```

UI/lifecycle:

- virtual keyboard does not open
- text appears once
- no visible flashing
- no uinput module required
- Upload Daemon restarts xochitl with the injector
- capture pauses on focus loss, resumes on refocus
- capture window follows across all Spaces
- no Dock icon (menu bar accessory)
