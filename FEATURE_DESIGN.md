# Feature Design: Select, Copy, and Paste

## Status

The design has passed the two risky implementation spikes:

- **Qt:** xochitl accepts selection and editing shortcuts through
  `qt_handleKeyEvent(QGuiApplication::focusWindow(), ...)`.
- **Modifiers:** Qt Control works; Alt does not work for paste and is not a
  supported fallback.
- **AppKit:** the Capture HUD's app-local key-down monitor captures letter
  shortcuts and Shift navigation before AppKit handles them locally.
- **Navigation flags:** Shift arrow events may include `.function` or
  `.numericPad`; those flags must not be treated as extra modifiers.

The current Swift implementation is still a probe: it displays detected editing
commands in the HUD but does not send type `0x03` frames yet. The remaining work
is production protocol wiring, ordered transmission, and final acceptance tests.

## Scope

Forward these commands from the Mac Capture HUD to the active text/document
editor in xochitl:

- Shift-based character and line selection
- copy, paste, and cut
- select all
- undo

Clipboard data remains on the tablet. Mac-to-tablet clipboard synchronization is
out of scope.

## Design decisions

1. Send semantic command names rather than raw macOS key codes.
2. Use Qt's normal window-level key-event route for editing commands.
3. Translate Mac Command to Qt Control.
4. Keep the existing direct focus-object path for Unicode text until the
   production route is shown to preserve its no-virtual-keyboard behavior.
5. Use one AppKit shortcut router; do not combine a local monitor with a second
   field-level router.

## Wire protocol

Frames use the existing format:

```text
[type: 1 byte][length: 4 bytes little-endian][payload]
```

| Type | Name | Payload |
|---|---|---|
| `0x01` | Text | UTF-8 text |
| `0x02` | Control key | Existing ASCII key name |
| `0x03` | Editing command | Exact ASCII command name |
| `0x04` | Hello | `RMKEY/1` |
| `0x05` | Hello acknowledgement | `RMKEY/1 EDITING_COMMANDS` |

The client sends Hello after opening the injector channel and enables editing
commands only after receiving the expected acknowledgement. This prevents an
old injector from appearing compatible while silently ignoring new frames.

Editing command payloads are limited to 32 bytes. Unknown commands are logged
and ignored. Editing commands do not require per-command acknowledgements.

### Command mapping

| Command | Mac trigger | Qt key and modifiers |
|---|---|---|
| `COPY` | `⌘C` | `Key_C`, `ControlModifier` |
| `PASTE` | `⌘V` | `Key_V`, `ControlModifier` |
| `CUT` | `⌘X` | `Key_X`, `ControlModifier` |
| `SELECT_ALL` | `⌘A` | `Key_A`, `ControlModifier` |
| `UNDO` | `⌘Z` | `Key_Z`, `ControlModifier` |
| `SHIFT_LEFT` | `⇧←` | `Key_Left`, `ShiftModifier` |
| `SHIFT_RIGHT` | `⇧→` | `Key_Right`, `ShiftModifier` |
| `SHIFT_UP` | `⇧↑` | `Key_Up`, `ShiftModifier` |
| `SHIFT_DOWN` | `⇧↓` | `Key_Down`, `ShiftModifier` |
| `SHIFT_HOME` | `⇧⌘←` | `Key_Home`, `ShiftModifier` |
| `SHIFT_END` | `⇧⌘→` | `Key_End`, `ShiftModifier` |

## Data flow

```text
Mac key event
  → app-local Capture HUD shortcut monitor
  → EditingCommand enum
  → ordered outbound frame queue
  → SSHActor.sendFrame()
  → SSH direct-tcpip channel
  → injector parser
  → Qt-main-thread dispatch
  → qt_handleKeyEvent(focusWindow(), ...)
  → Qt shortcut processing and focused QML item
```

All outgoing text, control, and editing frames must share one ordered sender.
Launching an independent unsequenced `Task` for every event can reorder text and
commands.

`SSHActor.sendFrame()` must loop until `libssh2_channel_write_ex()` writes the
complete frame. A short write must never be treated as success.

The injector listener must handle each client connection in a detached client
thread. A persistent Capture HUD channel must not block reconnects or diagnostics.
Qt callbacks remain queued onto the Qt main thread.

## Mac shortcut handling

`CaptureShortcutRouter.swift` owns the mapping and produces `EditingCommand`
values. It uses an app-local `.keyDown` monitor while the Capture field, or its
field editor, is the first responder.

The router must:

- consume `⌘C/V/X/A/Z`, `⇧` arrows, and `⌘⇧←/→`
- prevent AppKit from operating on the local transient field
- leave unmodified controls to the existing `doCommandBy` delegate path
- use hardware key codes for arrows, Home, and End
- use modifier-free AppKit characters for letter shortcuts
- reject Option and Control combinations
- allow `.function` and `.numericPad` flags for navigation keys
- ignore key-up events and key repeats
- remove its event monitor when the Capture view is destroyed

## Qt injector behavior

For editing commands, resolve the current focus window at dispatch time and call
Qt's exported helper:

```cpp
qt_handleKeyEvent(window, QEvent::KeyPress, key, modifiers,
                  QString(), false, 1);
qt_handleKeyEvent(window, QEvent::KeyRelease, key, modifiers,
                  QString(), false, 1);
```

`window` is `QGuiApplication::focusWindow()`. This route performs normal Qt
shortcut processing before delivering the event to the focused QML item. Do not
send the same editing command to both the focus object and focus window.

The target Qt 6.8.2 Gui library exports `qt_handleKeyEvent`, although its
published declaration is in Qt test-support headers. Use a weak forward
declaration so an unexpected runtime reports an injector capability error
instead of failing during library load. Do not add a QtTest runtime dependency.

The existing direct `QKeyEvent` path remains the text-frame implementation:
Unicode text is sent only to `QGuiApplication::focusObject()` to avoid duplicate
insertion and virtual-keyboard activation.

## Required changes

### `Sources/RMKeyApp/Core/FramedProtocol.swift`

- Add frame types `0x03`–`0x05`.
- Add `EditingCommand` encoders.
- Add exact-byte protocol tests.

### `Sources/RMKeyApp/Capture/CaptureShortcutRouter.swift`

- Keep the validated AppKit mapping.
- Replace the probe-only callback with a production command callback.

### `Sources/RMKeyApp/Capture/CaptureWindow.swift`

- Send detected commands through the ordered frame sender.
- Keep existing text and unmodified control-key behavior unchanged.

### `Sources/RMKeyApp/Core/SSHActor.swift`

- Implement complete channel writes.
- Perform and validate the Hello exchange.
- Serialize outgoing frames in capture order.
- Invalidate the injector channel on protocol failure.

### `daemon/rmkey-qt-inject.cpp`

- Add frame types `0x03`–`0x05`.
- Parse and validate editing commands.
- Implement Hello acknowledgement.
- Dispatch editing commands through `qt_handleKeyEvent` on the Qt main thread.
- Preserve the concurrent-client listener.

### Documentation

Update `docs/DESIGN.md`, README usage notes, and injector protocol comments when
production editing frames are implemented.

## Acceptance tests

### Client

- `⌘C/V/X/A/Z` displays and sends the correct semantic command.
- `⇧←/→/↑/↓` displays and sends the correct command.
- `⌘⇧←/→` maps to `SHIFT_HOME` / `SHIFT_END`.
- Key repeats do not duplicate commands.
- Option/control combinations are not intercepted.
- Focus loss stops command capture.
- Plain text and unmodified controls remain unchanged.

### Tablet

In xochitl text-edit mode:

1. Select text with Shift arrows.
2. Copy, move the cursor, and paste.
3. Verify cut, select all, and undo.
4. Verify no duplicate text or commands.
5. Verify the virtual keyboard does not open.
6. Reconnect and restart xochitl; verify Hello is required again.

## Explicit non-goals

- Mac-to-tablet clipboard synchronization.
- Redo, word-wise selection, and Option-based navigation.
- A configurable modifier setting.
- Per-command success acknowledgements.
