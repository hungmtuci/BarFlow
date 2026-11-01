import Foundation
import AppKit
import Carbon

@MainActor
final class HotKeyService: ObservableObject {
    static let shared = HotKeyService()

    /// Whether the user is currently recording a new global shortcut in the Settings UI.
    @Published private(set) var isRecordingShortcut: Bool = false

    /// Fired when the user presses the configured global hotkey anywhere in macOS.
    var onToggleSecondaryBar: (() -> Void)?
    /// Fired when the user presses `Esc` while the secondary bar is open.
    var onEscapePressed: (() -> Void)?
    /// Returns true if the secondary bar is currently visible.
    var isSecondaryBarVisible: (() -> Bool)?
    /// Fired when a new shortcut binding is recorded by the user.
    var onShortcutRecorded: ((HotKeyBinding) -> Void)?

    private var currentBinding: HotKeyBinding = .defaultCtrlB
    private var toggleHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var recordingLocalMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?

    private init() {}

    func registerHotKeys(binding: HotKeyBinding? = nil) {
        if let binding = binding {
            currentBinding = binding
        }

        installCarbonEventHandlerIfNeeded()
        registerCarbonToggleHotKey(for: currentBinding)
    }

    func updateBinding(_ newBinding: HotKeyBinding) {
        currentBinding = newBinding
        if !isRecordingShortcut {
            registerCarbonToggleHotKey(for: newBinding)
        }
    }

    // MARK: - Interactive Shortcut Recorder

    func toggleRecording() {
        if isRecordingShortcut {
            cancelRecording()
        } else {
            beginRecording()
        }
    }

    func beginRecording() {
        guard !isRecordingShortcut else { return }
        isRecordingShortcut = true

        // Temporarily unregister active Carbon hotkey so pressing the old shortcut can also be re-recorded cleanly
        if let ref = toggleHotKeyRef {
            UnregisterEventHotKey(ref)
            toggleHotKeyRef = nil
        }

        recordingLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self, self.isRecordingShortcut else { return event }

            let keyCode = UInt32(event.keyCode)
            let relevantFlags = event.modifierFlags.intersection([.command, .option, .control, .shift])

            // Plain Escape cancels recording without changing the current shortcut
            if Int(keyCode) == kVK_Escape && relevantFlags.isEmpty {
                self.cancelRecording()
                return nil
            }

            // Plain Delete / ForwardDelete resets back to Ctrl + B
            if (Int(keyCode) == kVK_Delete || Int(keyCode) == kVK_ForwardDelete) && relevantFlags.isEmpty {
                self.finishRecording(with: .defaultCtrlB)
                return nil
            }

            // Require at least Control, Option, or Command (unless F1–F12) so normal typing keys are never hijacked
            let hasPrimaryModifier = relevantFlags.contains(.control) ||
                relevantFlags.contains(.option) ||
                relevantFlags.contains(.command)
            guard hasPrimaryModifier || HotKeyBinding.isFunctionKey(keyCode) else {
                NSSound.beep()
                return nil
            }

            let carbonMods = HotKeyBinding.carbonModifiers(from: relevantFlags)
            let recorded = HotKeyBinding(keyCode: keyCode, carbonModifiers: carbonMods)
            self.finishRecording(with: recorded)
            return nil
        }

        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelRecording()
            }
        }
    }

    func cancelRecording() {
        guard isRecordingShortcut else { return }
        isRecordingShortcut = false
        cleanupRecordingMonitors()
        registerCarbonToggleHotKey(for: currentBinding)
    }

    private func finishRecording(with newBinding: HotKeyBinding) {
        isRecordingShortcut = false
        cleanupRecordingMonitors()
        currentBinding = newBinding
        registerCarbonToggleHotKey(for: newBinding)
        onShortcutRecorded?(newBinding)
    }

    private func cleanupRecordingMonitors() {
        if let mon = recordingLocalMonitor {
            NSEvent.removeMonitor(mon)
            recordingLocalMonitor = nil
        }
        if let obs = resignActiveObserver {
            NotificationCenter.default.removeObserver(obs)
            resignActiveObserver = nil
        }
    }

    // MARK: - Low-Level Carbon Hotkey Registration

    private func installCarbonEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }

            let id = hotKeyID.id
            Task { @MainActor in
                if id == 1 {
                    HotKeyService.shared.onToggleSecondaryBar?()
                }
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
    }

    private func registerCarbonToggleHotKey(for binding: HotKeyBinding) {
        if let ref = toggleHotKeyRef {
            UnregisterEventHotKey(ref)
            toggleHotKeyRef = nil
        }
        let toggleID = EventHotKeyID(signature: OSType(0x42464C57), id: 1) // 'BFLW'
        RegisterEventHotKey(
            binding.keyCode,
            binding.carbonModifiers,
            toggleID,
            GetApplicationEventTarget(),
            0,
            &toggleHotKeyRef
        )
    }

    /// Enables global & local `Escape` key monitors strictly while `SecondaryBarController` (`Ctrl + B`) is visible,
    /// avoiding 24/7 WindowServer keystroke IPC when BarFlow is idle in the background.
    func setEscapeMonitorsEnabled(_ enabled: Bool) {
        if enabled {
            if globalKeyMonitor == nil {
                globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                    guard event.keyCode == UInt16(kVK_Escape) else { return }
                    MainActor.assumeIsolated {
                        if HotKeyService.shared.isSecondaryBarVisible?() == true {
                            HotKeyService.shared.onEscapePressed?()
                        }
                    }
                }
            }

            if localKeyMonitor == nil {
                localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.keyCode == UInt16(kVK_Escape) else { return event }
                    let shouldConsume = MainActor.assumeIsolated { () -> Bool in
                        if HotKeyService.shared.isRecordingShortcut {
                            return false
                        }
                        if HotKeyService.shared.isSecondaryBarVisible?() == true {
                            HotKeyService.shared.onEscapePressed?()
                            return true
                        }
                        return false
                    }
                    return shouldConsume ? nil : event
                }
            }
        } else {
            if let monitor = globalKeyMonitor {
                NSEvent.removeMonitor(monitor)
                globalKeyMonitor = nil
            }
            if let monitor = localKeyMonitor {
                NSEvent.removeMonitor(monitor)
                localKeyMonitor = nil
            }
        }
    }

    func unregisterHotKeys() {
        cancelRecording()
        setEscapeMonitorsEnabled(false)
        if let ref = toggleHotKeyRef {
            UnregisterEventHotKey(ref)
            toggleHotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }
}
