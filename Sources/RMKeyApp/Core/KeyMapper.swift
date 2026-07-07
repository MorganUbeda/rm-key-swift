import AppKit

/// Control key names used in the wire protocol.
///
/// Maps NSEvent keyCode (hardware-level kVK_* constants) to protocol control names.
/// This is layout-independent — more reliable than keysym-based mapping.
enum ControlKey: String, CaseIterable {
    case backspace = "BACKSPACE"
    case delete = "DELETE"
    case enter = "ENTER"
    case left = "LEFT"
    case right = "RIGHT"
    case up = "UP"
    case down = "DOWN"
    case tab = "TAB"
    case escape = "ESCAPE"
    case home = "HOME"
    case end = "END"

    /// Map an NSEvent keyCode to a ControlKey, or nil if not a control key.
    init?(keyCode: UInt16) {
        switch Int(keyCode) {
        case 0x33: self = .backspace   // kVK_Delete
        case 0x75: self = .delete       // kVK_ForwardDelete
        case 0x24: self = .enter        // kVK_Return
        case 0x4C: self = .enter        // kVK_ANSI_KeypadEnter
        case 0x7B: self = .left         // kVK_LeftArrow
        case 0x7C: self = .right        // kVK_RightArrow
        case 0x7E: self = .up           // kVK_UpArrow
        case 0x7D: self = .down         // kVK_DownArrow
        case 0x30: self = .tab          // kVK_Tab
        case 0x35: self = .escape       // kVK_Escape
        case 0x73: self = .home         // kVK_Home
        case 0x77: self = .end          // kVK_End
        default: return nil
        }
    }
}
