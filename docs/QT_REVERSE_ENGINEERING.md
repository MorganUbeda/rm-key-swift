# Qt Stack Reverse Engineering Notes

## Conclusion

The original plan of sending a `QKeyEvent` directly to
`QGuiApplication::focusObject()` is sufficient for the already-validated
Unicode text path, but it is not the best path for editing shortcuts.

For editing commands, use Qt's window-system key entry point:

```cpp
qt_handleKeyEvent(
    QGuiApplication::focusWindow(),
    QEvent::KeyPress,
    Qt::Key_C,
    Qt::ControlModifier,
    QString(),
    false,
    1);
```

Send a matching `KeyRelease` event afterward. This lets Qt perform its normal
shortcut processing before delivering the event to the focused QML item.

## Local artifacts examined

The repository's current `tablet-sysroot` contains the target Qt 6.8.2 Core and
Gui libraries. A sibling local research checkout also contains:

- an extracted Paper Pro `xochitl` aarch64 binary
- `libQt6Quick.so.6.8.2`
- previous injector inspection logs

The binary and logs are research artifacts only; they are not part of this
repository's runtime or deployment process.

## Target Qt findings

The target libraries identify themselves as Qt 6.8.2, aarch64, little-endian.
The target `libQt6Gui.so.6` exports:

```text
qt_handleKeyEvent(QWindow*, QEvent::Type, int,
                  QFlags<Qt::KeyboardModifier>, QString const&,
                  bool, unsigned short)
```

The exact C++ signature is:

```cpp
void qt_handleKeyEvent(QWindow *window,
                       QEvent::Type type,
                       int key,
                       Qt::KeyboardModifiers modifiers,
                       const QString &text = QString(),
                       bool autorep = false,
                       ushort count = 1);
```

It is declared in Qt's `QtTest/qtestkeyboard.h`, but the implementation is
exported by `libQt6Gui.so.6` in the target runtime. The injector therefore does
not need to link against or deploy QtTest. It can use a Qt-namespace
forward declaration and link against the existing Gui library.

The target Gui binary also exports the internal shortcut machinery:

- `QWindowSystemInterface::handleKeyEvent`
- `QWindowSystemInterface::handleShortcutEvent`
- `QShortcutMap::tryShortcut`
- `qt_sendShortcutOverrideEvent`
- `QGuiApplicationPrivate::processKeyEvent`

These are useful evidence that the Qt window-system route is materially
different from a direct `QCoreApplication::sendEvent` call.

## Event-path evidence

The Qt 6.8.2 headers and disassembly show this path for a normal key press:

```text
qt_handleKeyEvent
  → QWindowSystemInterface key event
  → QGuiApplicationPrivate::processKeyEvent
  → shortcut processing / ShortcutOverride handling
  → QKeyEvent construction
  → spontaneous delivery to the focus object
```

For a key press, `processKeyEvent` attempts shortcut handling before normal
focus-object delivery. A direct call such as:

```cpp
QKeyEvent event(...);
QCoreApplication::sendEvent(QGuiApplication::focusObject(), &event);
```

starts at the final delivery stage and bypasses that earlier shortcut path.
That may still work for a custom `keyPressEvent`, but it is unsafe to assume it
will activate QML `Shortcut`s, actions, or context shortcuts.

The normal Qt route takes a `QWindow*`, not a `QObject*` focus item. It resolves
the active focus item during event processing, so the injector should pass
`QGuiApplication::focusWindow()`.

## xochitl findings

The extracted `xochitl` binary is a stripped aarch64 Qt Quick application. Its
needed libraries include:

- `libQt6Quick.so.6`
- `libQt6Qml.so.6`
- `libQt6Gui.so.6`
- `libQt6Core.so.6`

The binary imports or references:

- `QQuickItem::keyPressEvent` and `keyReleaseEvent`
- `QKeyEvent` construction and modifier inspection
- `QKeySequence` and `QKeySequence::StandardKey`
- `QClipboard`
- Qt Quick `Shortcut` infrastructure

The Qt Quick 6.8.2 library contains the expected text-editor behavior,
including `QQuickTextEdit` and `QQuickTextInput` implementations with:

- `keyPressEvent`
- selection movement
- `selectAll`
- `copy`
- `cut`
- `paste`
- `undo` / `redo`

However, xochitl's notebook editor is not necessarily a stock Qt text item. Its
binary contains custom types and actions including:

- `SceneView`
- `SceneTextItem`
- `SceneController`
- `SceneKeyHandlerAction`
- `copySelectedText`
- `cutSelectedText`
- `selectText`
- `selectTextRange`
- `pasteText`
- `undo` / `redo`
- `replaceText`

This means the event path is promising, but behavior must still be tested in
the actual notebook text mode.

## Runtime inspection evidence

Previous injector inspection logs show the active focus object as a generated
QML `SceneView` class, for example:

```text
focus object class=SceneView_QML_1871
```

The same inspection found a generated `DocumentView` with invokable methods:

```text
pasteFromShortcut(QVariant)
performPaste(QVariant)
enterTextMode(QVariant,QVariant)
exitTextMode(QVariant)
```

It also found `DocumentViewShortcuts` objects with `pasteFromShortcut` and
`pasteFromStroke` methods. These observations imply that paste may be handled
by xochitl's custom scene/document keyboard layer rather than a plain
`QQuickTextInput`.

The focus object is therefore the right conceptual target, but the injector
should reach it through Qt's normal `QWindow` event pipeline.

## Historical diagnostic spike

Add a temporary diagnostic command to the injector that runs only on the Qt
main thread and tests the following forms independently:

### Form A: normal Qt route

```cpp
qt_handleKeyEvent(window, QEvent::KeyPress, key, modifiers,
                  QString(), false, 1);
qt_handleKeyEvent(window, QEvent::KeyRelease, key, modifiers,
                  QString(), false, 1);
```

### Form B: direct focus-object route

Keep the current direct `QKeyEvent` implementation as a control comparison.
Do not send both forms for the same command during a real edit; that can run
the operation twice.

### Form C: full modifier lifecycle

If Form A fails, reproduce the sequence used by Qt's own `QTest::sendKeyEvent`:

```text
modifier press
key press with modifier flag
key release with modifier flag
modifier release
```

This determines whether xochitl depends only on `QKeyEvent::modifiers()` or on
modifier key state as well.

Test each form with:

- left/right selection
- copy, cut, paste
- select all
- undo
- redo if available

Record the focus-window class, focus-object class, key, modifier value, and
whether the screen/document changed. Do not infer success solely from a
transport write succeeding.

## Injector implementation guidance

Use a weak forward declaration matching the target symbol so an unexpected Qt
runtime fails as a logged capability error rather than during library load:

```cpp
QT_BEGIN_NAMESPACE
Q_GUI_EXPORT void qt_handleKeyEvent(
    QWindow *, QEvent::Type, int, Qt::KeyboardModifiers,
    const QString &, bool, ushort) __attribute__((weak));
QT_END_NAMESPACE
```

Check the function pointer before enabling editing commands. Call it only from
the Qt main-thread callback. Resolve the current focus window at dispatch time,
not when the network thread receives the command. Focus can change while a
frame is queued.

Keep direct `sendEvent(focusObject, ...)` for the existing Unicode text path
until the normal Qt route has been shown not to preserve its no-virtual-keyboard
behavior.

## Diagnostic test result

A temporary `0x7f` diagnostic frame was used during investigation and has been
removed from the production injector. It compared direct focus-object events,
the normal `qt_handleKeyEvent` route, and explicit modifier lifecycles.

All three routes worked for selection. Control worked for paste; Alt did not.
The diagnostic also exposed that the original single-client listener blocked
while the main rm-key app held its persistent connection. The production
listener now handles each client in a detached thread.

## Current validation status

Validated from local binaries and prior inspection artifacts:

- target Qt version is 6.8.2
- target architecture is aarch64
- Qt's normal key-event entry point is available in target Gui
- xochitl is Qt Quick-based
- xochitl has custom scene/document keyboard and clipboard layers
- focus-object delivery is already sufficient for Unicode insertion
- normal, direct, and full modifier routes work for selection
- Control is required for paste; Alt does not work
- the AppKit Capture HUD probe captures letter and Shift-navigation shortcuts
- navigation events may include `.function` or `.numericPad` flags
- the original single-client server behavior prevented diagnostics while the
  persistent app channel was open; the server now handles clients concurrently

Remaining feature work is production integration:

- implement the production `0x03` editing-command frame
- replace the Capture HUD probe callback with frame transmission
- add final copy/cut/select-all/undo acceptance coverage
