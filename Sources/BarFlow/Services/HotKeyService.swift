import Foundation
import AppKit
import Carbon

@MainActor
final class HotKeyService {
    static let shared = HotKeyService()

    /// Fired when the user presses `Ctrl + B` anywhere in macOS.
    var onToggleSecondaryBar: (() -> Void)?
    /// Fired when the user presses `Esc` while the secondary bar is open.
    var onEscapePressed: (() -> Void)?
    /// Returns true if the secondary bar is currently visible.
    var isSecondaryBarVisible: (() -> Bool)?

    private var toggleHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    private init() {}

    func registerHotKeys() {
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

        // Register Ctrl + B (kVK_ANSI_B = 11, controlKey = 4096)
        let toggleID = EventHotKeyID(signature: OSType(0x42464C57), id: 1) // 'BFLW'
        RegisterEventHotKey(
            UInt32(kVK_ANSI_B),
            UInt32(controlKey),
            toggleID,
            GetApplicationEventTarget(),
            0,
            &toggleHotKeyRef
        )

        // Escape key monitor when Secondary Bar is open
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                Task { @MainActor in
                    if HotKeyService.shared.isSecondaryBarVisible?() == true {
                        HotKeyService.shared.onEscapePressed?()
                    }
                }
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape),
               HotKeyService.shared.isSecondaryBarVisible?() == true {
                HotKeyService.shared.onEscapePressed?()
                return nil
            }
            return event
        }
    }

    func unregisterHotKeys() {
        if let ref = toggleHotKeyRef {
            UnregisterEventHotKey(ref)
            toggleHotKeyRef = nil
        }
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
