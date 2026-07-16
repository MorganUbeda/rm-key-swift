import SwiftUI
import AppKit

// MARK: - Custom NSTextField

/// NSTextField subclass that forwards text via textDidChange.
/// Dead keys compose naturally through the system input method.
final class CaptureTextField: NSTextField {
    var onText: ((String) -> Void)?

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        let text = stringValue
        if !text.isEmpty {
            onText?(text)
            stringValue = ""
        }
    }
}

// MARK: - SwiftUI wrapper

struct CaptureTextFieldRepresentable: NSViewRepresentable {
    @Binding var lastKey: String
    let appState: AppState

    func makeNSView(context: Context) -> CaptureTextField {
        let field = CaptureTextField(frame: .zero)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        field.placeholderString = "Type here…"
        field.delegate = context.coordinator
        context.coordinator.installShortcutProbe(for: field)
        field.onText = { text in
            let frame = FramedProtocol.encodeText(text)
            Task {
                do {
                    try await appState.sshActor.sendFrame(frame)
                    await MainActor.run { lastKey = text }
                } catch {
                    print("[rm-key] Send error: \(error)")
                }
            }
        }
        return field
    }

    func updateNSView(_ nsView: CaptureTextField, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState, lastKey: $lastKey)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        let appState: AppState
        var lastKey: Binding<String>
        private var shortcutMonitor: Any?

        init(appState: AppState, lastKey: Binding<String>) {
            self.appState = appState
            self.lastKey = lastKey
        }

        deinit {
            if let shortcutMonitor {
                NSEvent.removeMonitor(shortcutMonitor)
            }
        }

        /// Temporary client-side probe for the AppKit interception boundary.
        /// It consumes only editing shortcuts while this field is active and
        /// displays the command in the HUD instead of sending a frame.
        func installShortcutProbe(for field: CaptureTextField) {
            shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                [weak self, weak field] event in
                guard let self, let field,
                      let window = field.window,
                      window.firstResponder === field
                          || field.currentEditor() === window.firstResponder,
                      let command = EditingCommand.command(for: event) else {
                    return event
                }

                print("[rm-key] Capture shortcut probe: \(command.rawValue)")
                self.lastKey.wrappedValue = command.rawValue
                return nil
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let controlKey = controlKey(for: commandSelector) else {
                return false
            }
            let frame = FramedProtocol.encodeControl(controlKey)
            Task {
                do {
                    try await appState.sshActor.sendFrame(frame)
                    await MainActor.run { lastKey.wrappedValue = controlKey.rawValue }
                } catch {
                    print("[rm-key] Send error: \(error)")
                }
            }
            return true
        }

        private func controlKey(for selector: Selector) -> ControlKey? {
            switch selector {
            case #selector(NSResponder.moveLeft(_:)):               return .left
            case #selector(NSResponder.moveRight(_:)):              return .right
            case #selector(NSResponder.moveUp(_:)):                 return .up
            case #selector(NSResponder.moveDown(_:)):               return .down
            case #selector(NSResponder.deleteBackward(_:)):         return .backspace
            case #selector(NSResponder.deleteForward(_:)):          return .delete
            case #selector(NSResponder.insertNewline(_:)):          return .enter
            case #selector(NSResponder.insertTab(_:)):              return .tab
            case #selector(NSResponder.cancelOperation(_:)):        return .escape
            case #selector(NSResponder.moveToBeginningOfLine(_:)):  return .home
            case #selector(NSResponder.moveToEndOfLine(_:)):        return .end
            default: return nil
            }
        }
    }
}

// MARK: - Capture view

struct CaptureViewContent: View {
    @Bindable var appState: AppState
    @State private var lastKey = ""

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                Text("Connected — type below")
                    .font(.system(size: 11, weight: .medium))

                Spacer()
            }

            CaptureTextFieldRepresentable(lastKey: $lastKey, appState: appState)
                .frame(height: 30)

            Text(lastKey.isEmpty ? " " : lastKey)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)

            Button(action: stopCapture) {
                Text("Stop Capture")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(width: 260)
        .onAppear {
            appState.captureWindowOpen = true
        }
        .onDisappear {
            appState.captureWindowOpen = false
        }
    }

    private var statusColor: Color {
        appState.connectionState == .connected ? .green : .orange
    }

    private func stopCapture() {
        appState.captureWindowOpen = false
        for window in NSApp.windows where window.title == "Capture" {
            window.close()
        }
        NSApp.setActivationPolicy(.accessory)
    }
}
