import Foundation

/// Wire protocol encoder for framed messages to the Qt injector.
///
/// Frame format:
///   [type:1 byte][length:4 bytes LE][payload:length bytes]
enum FramedProtocol {
    enum FrameType: UInt8 {
        case text = 0x01
        case control = 0x02
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

    private static func encodeFrame(type: FrameType, payload: Data) -> Data {
        var frame = Data(capacity: 5 + payload.count)
        frame.append(type.rawValue)
        let length = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }
}
