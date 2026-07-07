# AGENTS.md

## Project Overview

rm-key sends keystrokes from a Mac to a reMarkable Paper Pro over SSH.
A native Swift macOS app captures key presses and forwards them over SSH
as framed protocol messages to an LD_PRELOAD Qt injector running inside
xochitl on the tablet, which injects synthetic QKeyEvent into the focused
Qt object.

The app runs as a menu bar accessory (no Dock icon) with three coordinated
windows: MenuBarExtra, Settings, and a Capture HUD.

See docs/DESIGN.md for the full architecture and protocol details.

## Tech Stack

- **Language:** Swift 5.9+
- **Package manager:** SwiftPM (`swift build`)
- **UI:** SwiftUI (macOS 14+), with AppKit bridges where needed (NSTextField, NSWindow)
- **SSH:** libssh2 via a SwiftPM system-library target (`Clibssh2`)
- **Injector:** C++ (Qt), cross-compiled to aarch64 via nix (build-injector.nix)

## No Guesswork

**Never guess package names, API details, build configuration, or anything you are not certain about.**

When unsure:
1. **Read the locally available docs first** — check source files, Nix store paths, `nix eval`, grep the codebase, read `DESIGN.md`, etc.
2. **If local docs are insufficient, check online** — use web search or fetch the relevant documentation page.
3. Only then make changes, and always cite your source.

Examples:
- Don't guess Nixpkgs cross-compiler attribute names — read `lib/systems/examples.nix` from the nixpkgs source in `/nix/store`.
- Don't guess libssh2 API details — read local headers or upstream docs first.
- Don't guess file paths — search the filesystem first.

## Dependency Management

**Use SwiftPM for all Swift dependencies.** Dependencies are declared in `Package.swift`.

To add a dependency:
1. Add the package URL and version to `dependencies` in `Package.swift`.
2. Add the product to the target's `dependencies`.

```swift
// Example: adding a new dependency
dependencies: [
    .package(url: "https://github.com/example/package.git", from: "1.0.0"),
],
targets: [
    .executableTarget(
        name: "RMKeyApp",
        dependencies: [
            .product(name: "ExampleLib", package: "package"),
        ],
    ),
]
```

## Code Formatting

**All Swift code must be formatted with `swift-format`.**

```bash
swift-format --in-place --recursive Sources/
```

Run swift-format before committing.

## Git Commits

**Never commit code unless explicitly instructed to do so.**

When you are asked to commit, use conventional commit format with scope:

```
[type](scope): description
```

Types:
- `feat` — new feature
- `fix` — bug fix
- `doc` — documentation changes
- `refactor` — code refactoring (no new features, no bug fixes)
- `chore` — maintenance tasks, build config, dependencies
- `test` — adding or updating tests

Scope: the component being changed (e.g., `menu`, `capture`, `daemon`, `ssh`, `deps`)

Examples:
```
feat(capture): add capture HUD window with AppKit text field
fix(ssh): reconnect on connection drop with backoff
doc(readme): update build instructions for Swift client
chore(deps): update libssh2 integration
```

## Building & Running

```bash
# Build the Qt injector (tablet side, cross-compiled for aarch64)
nix-build build-injector.nix
# output: result/librmkey_qt_inject.so

# Copy injector into the app bundle resources
cp result/librmkey_qt_inject.so Sources/RMKeyApp/Resources/

# Build the Swift client
swift build -c release
# binary: .build/release/RMKeyApp

# Run directly
swift run -c release
```

## Injector Cross-Compilation

The Qt injector must be cross-compiled for aarch64 from your Mac:

```bash
nix-build build-injector.nix
```

This uses `pkgs.pkgsCross.aarch64-multiplatform` to produce a dynamically-linked
shared library linking against Qt6Core and Qt6Gui. The build requires the tablet's
Qt libraries, fetched from the device into `tablet-sysroot/usr/lib/`.

For interactive C++ development, use `nix-shell` which provides an aarch64
cross-compiler (`aarch64-unknown-linux-gnu-gcc`) in the PATH.

**Do not attempt to deploy the injector manually via raw SSH commands.**
Deployment is done through the app's Upload Daemon button. There is a risk of
bricking the device if the wrong binary or commands are used.

## Key Files

| Path | Purpose |
|------|---------|
| `Sources/RMKeyApp/App.swift` | @main entry, activation policy, scene setup |
| `Sources/RMKeyApp/AppState.swift` | @Observable shared state (connection, capture, status) |
| `Sources/RMKeyApp/MenuBar/MenuBarView.swift` | MenuBarExtra content |
| `Sources/RMKeyApp/Settings/SettingsView.swift` | IP/password/upload window |
| `Sources/RMKeyApp/Capture/CaptureWindow.swift` | HUD window with AppKit text field capture |
| `Sources/RMKeyApp/Core/SSHActor.swift` | SSH connection management via libssh2 |
| `Sources/RMKeyApp/Core/FramedProtocol.swift` | Wire protocol encoder (type + length + payload) |
| `Sources/RMKeyApp/Core/KeyMapper.swift` | ControlKey enum and legacy keyCode mapping |
| `Sources/RMKeyApp/Core/Deployer.swift` | Upload injector, install drop-in, restart xochitl |
| `Sources/RMKeyApp/Core/CredentialStore.swift` | macOS Keychain read/write |
| `Sources/RMKeyApp/Resources/` | Bundled injector .so (built separately) |
| `Package.swift` | SwiftPM project manifest |
| `daemon/rmkey-qt-inject.cpp` | C++ source for the Qt injector |
| `shell.nix` | nix-shell: aarch64 cross-compiler |
| `build-injector.nix` | nix derivation for the Qt injector .so |

## Testing

No automated tests yet. Manual testing flow:
1. Build injector: `nix-build build-injector.nix`
2. Copy: `cp result/librmkey_qt_inject.so Sources/RMKeyApp/Resources/`
3. Build app: `swift build -c release`
4. Run: `swift run -c release`
5. Click menu bar icon → Settings → enter IP and password → Save
6. Click Upload Daemon → wait for completion
7. Click Start Capture → focus the capture HUD → type keys
8. Verify keystrokes appear on the reMarkable screen
9. Test focus loss: Cmd+Tab away → verify capture stops because the HUD is not focused; click back → verify typing resumes
