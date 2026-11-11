import Carbon

/// Keyboard shortcuts that reach this app whichever app is in front, ahead of that app's own menus.
///
/// `RegisterEventHotKey` rather than an event tap: only the exact shortcuts wake this process, typing passes by it
/// without delay, and nothing can stall input for the rest of the system if this process is slow. It is an old API
/// and still the supported one, and it needs no permission.
final class GlobalHotKeys {
    struct Shortcut: Hashable {
        let keyCode: Int
        let modifiers: Int
    }

    private static let signature: OSType = 0x5457_4B59  // "TWKY"

    private let onPress: (Shortcut) -> Void
    private var handler: EventHandlerRef?
    private var registered: [Shortcut: (id: UInt32, reference: EventHotKeyRef)] = [:]
    /// Shared by every instance: Finder cut and the task manager each keep their own, and every handler on the app's
    /// event target sees every hot key, so the numbers must tell their shortcuts apart across the whole app.
    private static var nextID: UInt32 = 1

    init(onPress: @escaping (Shortcut) -> Void) {
        self.onPress = onPress
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(), globalHotKeyCallback, 1, &event,
            Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// Call before releasing this object, which the system's handler refers to.
    func invalidate() {
        for shortcut in Array(registered.keys) { set(shortcut, enabled: false) }
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    /// Does nothing if the shortcut is already in the wanted state, so it can be called freely.
    func set(_ shortcut: Shortcut, enabled: Bool) {
        if enabled, registered[shortcut] == nil {
            // A key code from damaged settings would otherwise stop the app here.
            guard let keyCode = UInt32(exactly: shortcut.keyCode), let modifiers = UInt32(exactly: shortcut.modifiers)
            else { return }
            var reference: EventHotKeyRef?
            let id = Self.nextID
            Self.nextID &+= 1
            let status = RegisterEventHotKey(
                keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0,
                &reference)
            // Another app holding the shortcut leaves it working as before, which is the right way to fail.
            if status == noErr, let reference { registered[shortcut] = (id, reference) }
        } else if !enabled, let entry = registered.removeValue(forKey: shortcut) {
            UnregisterEventHotKey(entry.reference)
        }
    }

    /// False when the shortcut is another instance's, which then gets its turn.
    fileprivate func pressed(id: UInt32) -> Bool {
        guard let shortcut = registered.first(where: { $0.value.id == id })?.key else { return false }
        onPress(shortcut)
        return true
    }
}

/// The system delivers these on the main thread, through the app's event loop.
private nonisolated func globalHotKeyCallback(
    _ call: EventHandlerCallRef?, _ event: EventRef?, _ info: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let info else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    let number = id.id
    // The address as a number, which is safe to carry across, since this is the main thread and stays on it.
    let address = UInt(bitPattern: info)
    let handled = MainActor.assumeIsolated { () -> Bool in
        guard let pointer = UnsafeRawPointer(bitPattern: address) else { return false }
        return Unmanaged<GlobalHotKeys>.fromOpaque(pointer).takeUnretainedValue().pressed(id: number)
    }
    // Handled stops the event here, so another instance's shortcut must be passed on to its handler.
    return handled ? noErr : OSStatus(eventNotHandledErr)
}

#if TWEAKLY_AUTOMATION
    extension GlobalHotKeys {
        /// Two instances, as Finder cut and the task manager keep, each with a shortcut of its own, and a hot key event for
        /// each sent through the app's event target as the system sends it. Each press must reach its own instance alone.
        /// No key is pressed: the events are made here.
        static func selfTest() -> String {
            var heard: [String] = []
            let first = GlobalHotKeys { _ in heard.append("first") }
            let second = GlobalHotKeys { _ in heard.append("second") }
            let control = Int(controlKey | optionKey | shiftKey | cmdKey)
            let one = Shortcut(keyCode: Int(kVK_F19), modifiers: control)
            let two = Shortcut(keyCode: Int(kVK_F18), modifiers: control)
            first.set(one, enabled: true)
            second.set(two, enabled: true)
            var lines: [String] = []
            for (name, instance, shortcut) in [("first", first, one), ("second", second, two)] {
                guard let id = instance.registered[shortcut]?.id else {
                    lines.append("\(name): not registered")
                    continue
                }
                heard = []
                var event: EventRef?
                CreateEvent(
                    nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), GetCurrentEventTime(),
                    EventAttributes(kEventAttributeNone), &event)
                var hotKey = EventHotKeyID(signature: signature, id: id)
                SetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    MemoryLayout<EventHotKeyID>.size, &hotKey)
                SendEventToEventTarget(event, GetApplicationEventTarget())
                if let event { ReleaseEvent(event) }
                lines.append("\(name) id \(id): heard by \(heard.isEmpty ? "nobody" : heard.joined(separator: ", "))")
            }
            first.invalidate()
            second.invalidate()
            return lines.joined(separator: "\n") + "\n"
        }
    }
#endif
