import AppKit

/// Semantic editing commands produced by the Capture HUD.
///
/// This is currently used by the Capture HUD probe. The eventual handler will
/// encode these values as type-0x03 protocol frames.
enum EditingCommand: String, CaseIterable {
    case copy = "COPY"
    case paste = "PASTE"
    case cut = "CUT"
    case selectAll = "SELECT_ALL"
    case undo = "UNDO"
    case shiftLeft = "SHIFT_LEFT"
    case shiftRight = "SHIFT_RIGHT"
    case shiftUp = "SHIFT_UP"
    case shiftDown = "SHIFT_DOWN"
    case shiftHome = "SHIFT_HOME"
    case shiftEnd = "SHIFT_END"

    /// Map a key-down event using the same shortcuts the feature will expose.
    /// Arrow/navigation keys use hardware key codes; letter shortcuts use the
    /// characters AppKit reports with modifiers removed.
    static func command(for event: NSEvent) -> EditingCommand? {
        guard event.type == .keyDown, !event.isARepeat else { return nil }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        // Navigation keys can carry AppKit's .function/.numericPad flags even
        // when the user is only holding Shift or Command. Those flags describe
        // the physical key, not an extra shortcut modifier.
        let hasUnsupportedModifier = flags.contains(.option)
            || flags.contains(.control)
        guard !hasUnsupportedModifier else { return nil }

        switch (command, shift, Int(event.keyCode)) {
        case (true, true, 0x7B): return .shiftHome   // Left
        case (true, true, 0x7C): return .shiftEnd    // Right
        case (false, true, 0x7B): return .shiftLeft
        case (false, true, 0x7C): return .shiftRight
        case (false, true, 0x7E): return .shiftUp
        case (false, true, 0x7D): return .shiftDown
        default: break
        }

        guard command, !flags.contains(.function),
              let characters = event.charactersIgnoringModifiers?.lowercased(),
              characters.count == 1 else {
            return nil
        }

        switch characters {
        case "c": return .copy
        case "v": return .paste
        case "x": return .cut
        case "a": return .selectAll
        case "z": return .undo
        default: return nil
        }
    }
}
