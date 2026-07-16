import Foundation

/// Wire protocol encoder for framed messages to the Qt injector.
///
/// Frame format:
///   [type:1 byte][length:4 bytes LE][payload:length bytes]
enum FramedProtocol {
    enum FrameType: UInt8 {
        case text = 0x01
        case control = 0x02
        case editingCommand = 0x03
    }

    /// Encode a UTF-8 text frame.
    static func encodeText(_ text: String) -> Data {
        let payload = Data(text.utf8)
        return encodeFrame(type: .text, payload: payload)
    }

    /// Encode a control key frame.
    static func encodeControl(_ key: ControlKey) -> Data {
        let payload = Data(key.rawValue.utf8)
        return encodeFrame(type: .control, payload: payload)
    }

    /// Encode an editing-command frame.
    static func encodeEditingCommand(_ command: EditingCommand) -> Data {
        let raw = command.rawValue
        guard raw.utf8.count <= 32 else {
            print("ERROR FramedProtocol: editing command raw value too long (\(raw.utf8.count) bytes, max 32)")
            return Data()
        }
        let payload = Data(raw.utf8)
        return encodeFrame(type: .editingCommand, payload: payload)
    }


    private static func encodeFrame(type: FrameType, payload: Data) -> Data {
        var frame = Data(capacity: 5 + payload.count)
        frame.append(type.rawValue)
        let length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }
}

/// Semantic editing commands sent as type-0x03 protocol frames.
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
}
