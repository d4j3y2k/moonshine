import AppKit
import Carbon

final class HotKey {
    static let choices: [(label: String, code: UInt32, modifiers: UInt32)] = [
        ("⌃⌥M  Control–Option–M", UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey)),
        ("⌃⇧Space  Control–Shift–Space", UInt32(kVK_Space), UInt32(controlKey | shiftKey)),
        ("⌘⌥M  Command–Option–M", UInt32(kVK_ANSI_M), UInt32(cmdKey | optionKey))
    ]
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var activeIndex: Int?
    var onPress: (() -> Void)?
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let pointer, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == 0x4D4F4F4E else { return OSStatus(eventNotHandledErr) }
            Unmanaged<HotKey>.fromOpaque(pointer).takeUnretainedValue().onPress?()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(index: Int) throws {
        let index = Self.choices.indices.contains(index) ? index : 0
        guard activeIndex != index else { return }
        let choice = Self.choices[index]
        // Inspect active system shortcuts as well as asking Carbon to reject conflicts.
        let symbolic = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys")?["AppleSymbolicHotKeys"] as? [String: [String: Any]] ?? [:]
        var cocoaModifiers: UInt32 = 0
        if choice.modifiers & UInt32(controlKey) != 0 { cocoaModifiers |= 1 << 18 }
        if choice.modifiers & UInt32(optionKey) != 0 { cocoaModifiers |= 1 << 19 }
        if choice.modifiers & UInt32(cmdKey) != 0 { cocoaModifiers |= 1 << 20 }
        if choice.modifiers & UInt32(shiftKey) != 0 { cocoaModifiers |= 1 << 17 }
        let conflict = symbolic.values.contains { value in
            guard (value["enabled"] as? Bool) == true,
                  let details = value["value"] as? [String: Any], let params = details["parameters"] as? [NSNumber], params.count == 3 else { return false }
            return params[1].uint32Value == choice.code && params[2].uint32Value == cocoaModifiers
        }
        guard !conflict, handler != nil else { throw NSError(domain: "Moonshine", code: 1, userInfo: [NSLocalizedDescriptionKey: "This shortcut is already assigned by macOS. Choose another in Settings."]) }
        var replacement: EventHotKeyRef?
        let code = RegisterEventHotKey(choice.code, choice.modifiers, EventHotKeyID(signature: 0x4D4F4F4E, id: UInt32(index + 1)), GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &replacement)
        guard code == noErr else { throw NSError(domain: "Moonshine", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "The shortcut is in use (macOS \(code)). Moonshine is still available in the menu bar."]) }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement; activeIndex = index
    }
    deinit { if let hotKey { UnregisterEventHotKey(hotKey) }; if let handler { RemoveEventHandler(handler) } }
}
