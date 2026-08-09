// FluxApp.Input — macOS global input engine.
//
// Owns the physical Caps Lock capture (IOHIDManager input-value callbacks),
// the suppressing session event tap (CoreGraphics), and the platform-neutral
// routing state (InputRouter + ModifierStateTracker). Every routed action is
// executed against the injected context/focus/pointer controllers; all
// synthetic output carries the shared `SyntheticEventMarker` so Flux output
// never loops back into Flux input (design spec §7).
//
// Concurrency contract (design spec §7, §8): the IOHID manager and the
// event-tap run-loop source are both scheduled on the main run loop, so both
// C callbacks run on the main thread. The event-tap callback must decide
// pass/suppress synchronously and therefore uses `MainActor.assumeIsolated`;
// the HID callback extracts the raw Caps state synchronously (the value is
// only valid during the callback) and forwards it to the main actor with
// `MainActor.assumeIsolated`, preserving HID delivery order ahead of any
// following CG key event. No blocking work ever runs inside a callback.
//
// Privacy boundary (design spec §8): diagnostic logs carry only constant
// state plus IOReturn/error codes. Key codes, coordinates, and content are
// never logged.

// CoreGraphics' CF types are not annotated Sendable; the compiler suggests
// @preconcurrency because every CGEvent here is created and consumed on the
// main run loop and never shared across concurrency domains.
@preconcurrency import CoreGraphics
import FluxCore
import Foundation
import IOKit

/// Owns the global keyboard input path for Flux.
///
/// Lifecycle: `start()` installs the HID manager and the event tap and is
/// idempotent; `stop()` removes both and resets every piece of transient
/// state. The engine never starts in `init`. While paused, ordinary physical
/// keyboard events pass through unchanged, physical Caps stays inert, and
/// only `Caps + Command + Escape` resumes (design spec §8).
@MainActor
final class MacOSGlobalInputEngine {
    // MARK: - Dependencies

    private let contextRuntime: MacOSContextRuntime
    private let focusController: MacOSFocusController
    private let pointerController: MacOSPointerController

    // MARK: - Routed state

    private var router = InputRouter()
    private var modifierTracker = ModifierStateTracker()

    // MARK: - Lifecycle / pause

    private var isRunning = false

    /// Whether Flux input mapping is paused (design spec §8).
    private(set) var isPaused = false

    /// Invoked on the main actor whenever `isPaused` changes.
    var onPauseStateChange: ((Bool) -> Void)?

    // MARK: - Physical Caps capture

    /// Last raw Caps Lock state forwarded by the HID callback (nil before
    /// the first change), used to deduplicate repeated identical raw states.
    private var lastRawCapsState: Bool?

    // MARK: - Engine-side key suppression

    /// Physical keys whose keyDown the engine suppressed itself — the
    /// resume `Caps + Command + Escape` and the running-mode
    /// `Caps + Command + Escape` pause chord — so their matching keyUp stays
    /// suppressed even after a pause transition reset the router's own
    /// suppression tables. Cleared by the matching keyUp and by every
    /// transient reset (stop / tap disable / pause transitions).
    private var manualSuppressedKeys: Set<PhysicalKey> = []

    // MARK: - CF handles

    // The handles are only mutated on the main thread. They are marked
    // `nonisolated(unsafe)` so `deinit` can tear them down without an actor
    // hop after the last strong reference drops (no callback can fire then).
    private nonisolated(unsafe) var hidManager: IOHIDManager?
    private nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var eventTapSource: CFRunLoopSource?

    init(
        contextRuntime: MacOSContextRuntime,
        focusController: MacOSFocusController,
        pointerController: MacOSPointerController
    ) {
        self.contextRuntime = contextRuntime
        self.focusController = focusController
        self.pointerController = pointerController
    }

    deinit {
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let manager = hidManager {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    // MARK: - Lifecycle

    /// Installs the HID manager and the suppressing event tap. Idempotent:
    /// a second call while already running returns true without re-installing.
    /// Never called from `init`.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        resetTransientState()
        guard installHIDManager() else { return false }
        guard installEventTap() else {
            teardownHIDManager()
            return false
        }
        isRunning = true
        return true
    }

    /// Removes the event tap and the HID manager and resets every piece of
    /// transient state. Idempotent.
    func stop() {
        guard isRunning else { return }
        resetTransientState()
        teardownEventTap()
        teardownHIDManager()
        isRunning = false
    }

    // MARK: - HID installation

    private func installHIDManager() -> Bool {
        // The SDK overlay declares IOHIDManagerCreate non-optional; a
        // creation failure would surface as a nil dereference, so the
        // manager is used directly and failures are detected at open.
        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        hidManager = manager
        // Match keyboard devices (Generic Desktop / Keyboard application
        // collection) so the manager only enumerates keyboards.
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        // Deliver only the physical Caps Lock element; every other keyboard
        // value is never delivered (design spec §10). The callback's own
        // usage-page/usage guard remains as defense in depth.
        let elementMatching: [String: Any] = [
            kIOHIDElementUsagePageKey as String: kHIDPage_KeyboardOrKeypad,
            kIOHIDElementUsageKey as String: kHIDUsage_KeyboardCapsLock,
        ]
        IOHIDManagerSetInputValueMatching(manager, elementMatching as CFDictionary)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            NSLog("Flux: input engine: HID manager open failed (IOReturn %d)", openResult)
            teardownHIDManager()
            return false
        }
        IOHIDManagerRegisterInputValueCallback(
            manager,
            Self.hidInputValueCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        return true
    }

    private func teardownHIDManager() {
        guard let manager = hidManager else { return }
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = nil
    }

    // MARK: - Event tap installation

    private func installEventTap() -> Bool {
        let eventsOfInterest: CGEventMask = (UInt64(1) << UInt64(CGEventType.keyDown.rawValue))
            | (UInt64(1) << UInt64(CGEventType.keyUp.rawValue))
            | (UInt64(1) << UInt64(CGEventType.flagsChanged.rawValue))
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventsOfInterest,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Flux: input engine: event tap creation failed")
            return false
        }
        eventTap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            NSLog("Flux: input engine: event tap run loop source creation failed")
            teardownEventTap()
            return false
        }
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func teardownEventTap() {
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTapSource = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
    }

    // MARK: - C callbacks

    /// HID input-value callback: filters the value to the physical Caps Lock
    /// element (usage page `kHIDPage_KeyboardOrKeypad`, usage
    /// `kHIDUsage_KeyboardCapsLock`) and forwards the raw state synchronously
    /// to the main actor. The HID manager is scheduled on the main run loop,
    /// so the callback runs on the main thread and delivery order is
    /// preserved.
    private static let hidInputValueCallback: IOHIDValueCallback = { context, _, _, value in
        guard let context else { return }
        let engine = Unmanaged<MacOSGlobalInputEngine>.fromOpaque(context).takeUnretainedValue()
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad),
              IOHIDElementGetUsage(element) == UInt32(kHIDUsage_KeyboardCapsLock) else {
            return
        }
        let rawState = IOHIDValueGetIntegerValue(value)
        // The manager is scheduled on the main run loop, so this callback
        // runs on the main thread; the raw state is forwarded synchronously
        // to preserve HID delivery order ahead of any following CG key event
        // (a dispatch hop would reorder Caps behind the next keyDown).
        MainActor.assumeIsolated {
            engine.handleCapsRawState(rawState)
        }
    }

    /// Event-tap callback. The tap's run-loop source is scheduled on the
    /// main run loop, so this runs on the main thread and can assume
    /// main-actor isolation synchronously; the pass/suppress decision is
    /// made in place and no blocking work runs here (design spec §7).
    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else {
            return Unmanaged.passUnretained(event)
        }
        let engine = Unmanaged<MacOSGlobalInputEngine>.fromOpaque(refcon).takeUnretainedValue()
        return MainActor.assumeIsolated {
            engine.handleEventTap(type: type, event: event)
        }
    }

    // MARK: - Event tap handling

    @MainActor
    private func handleEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system disabled the tap (timeout or user input). Reset
            // transient state synchronously and re-enable it (design spec
            // §7, §10: a lifecycle interruption must never leak a held key
            // or a stale suppression).
            resetTransientState()
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return nil
        default:
            break
        }

        // Synthetic Flux output passes through without touching state.
        guard event.getIntegerValueField(.eventSourceUserData) != SyntheticEventMarker.value else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .flagsChanged:
            return handleFlagsChanged(event)
        case .keyDown:
            return handleKeyDown(event)
        case .keyUp:
            return handleKeyUp(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    @MainActor
    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let key = PhysicalKey(rawCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
        if key == .caps {
            // Physical Caps Lock state is captured by the HID manager; the
            // flagsChanged event is always suppressed and never forwarded
            // (design spec §10).
            return nil
        }
        guard let aggregate = Self.aggregateFlag(for: key) else {
            return Unmanaged.passUnretained(event)
        }
        guard let transition = modifierTracker.transition(
            for: key,
            aggregateIsActive: event.flags.contains(aggregate)
        ) else {
            return Unmanaged.passUnretained(event)
        }
        if isPaused {
            // While paused modifiers are still tracked (the resume chord
            // needs Command) but never routed; the physical event passes
            // through unchanged.
            return Unmanaged.passUnretained(event)
        }
        let inputEvent = InputEvent(
            key: key,
            modifiers: transition.modifiers,
            isSynthetic: false,
            kind: .modifierChanged(isDown: transition.isDown)
        )
        let action = router.route(inputEvent, frontmost: frontmostContext())
        return execute(action, original: event, isRepeat: false)
    }

    @MainActor
    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let key = PhysicalKey(rawCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        // OS autorepeat keyDowns of an engine-suppressed key (the pause /
        // resume Escape, still held through the transition) can arrive
        // before its matching keyUp; only keyUp previously consulted
        // manualSuppressedKeys, so those repeats leaked through routing.
        // Suppress them here, before paused/active routing, while leaving
        // repeats of unrelated keys untouched.
        if isRepeat, manualSuppressedKeys.contains(key) {
            return nil
        }
        if isPaused {
            // The only chord recognized while paused is the resume chord
            // Caps + Command + Escape (design spec §8); everything else
            // passes through unchanged.
            if lastRawCapsState == true, modifierTracker.modifiers.command, key == .escape {
                togglePause()
                // togglePause reset every manual suppression; record the
                // resume Escape so its matching keyUp stays suppressed.
                manualSuppressedKeys.insert(.escape)
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        let inputEvent = InputEvent(
            key: key,
            modifiers: modifierTracker.modifiers,
            isSynthetic: false,
            kind: .keyDown(isRepeat: isRepeat)
        )
        let action = router.route(inputEvent, frontmost: frontmostContext())
        let result = execute(action, original: event, isRepeat: isRepeat)
        if action == .togglePause {
            // togglePause reset every manual suppression; record the pause
            // chord Escape so its matching keyUp stays suppressed while
            // paused.
            manualSuppressedKeys.insert(key)
        }
        return result
    }

    @MainActor
    private func handleKeyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let key = PhysicalKey(rawCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
        // Engine-side suppressions are consumed before the pause branch: the
        // resume Escape's keyUp arrives after the pause transition, so it
        // must be suppressed in active mode too (design spec §8).
        if manualSuppressedKeys.remove(key) != nil {
            return nil
        }
        if isPaused {
            return Unmanaged.passUnretained(event)
        }
        let inputEvent = InputEvent(
            key: key,
            modifiers: modifierTracker.modifiers,
            isSynthetic: false,
            kind: .keyUp
        )
        let action = router.route(inputEvent, frontmost: frontmostContext())
        return execute(action, original: event, isRepeat: false)
    }

    // MARK: - HID handling

    /// Consumes one raw physical Caps Lock state change forwarded by the
    /// HID callback (main actor, synchronous). Repeated identical raw states
    /// are deduplicated so only real press/release transitions reach the
    /// router.
    @MainActor
    private func handleCapsRawState(_ rawState: CFIndex) {
        guard isRunning else { return }
        let isDown = rawState != 0
        guard isDown != lastRawCapsState else { return }
        lastRawCapsState = isDown
        if isPaused {
            // Caps stays inert while paused: raw state is tracked (so the
            // resume chord can detect a held Caps) but never routed.
            return
        }
        let inputEvent = InputEvent(
            key: .caps,
            modifiers: modifierTracker.modifiers,
            isSynthetic: false,
            kind: .capsChanged(isDown: isDown)
        )
        let action = router.route(inputEvent, frontmost: frontmostContext())
        _ = execute(action, original: nil, isRepeat: false)
    }

    // MARK: - Action execution

    /// Executes one routed action. Returns the event to pass through (the
    /// original for `.passThrough`), or nil to suppress the original event.
    @MainActor
    private func execute(
        _ action: InputAction,
        original: CGEvent?,
        isRepeat: Bool
    ) -> Unmanaged<CGEvent>? {
        switch action {
        case .passThrough:
            guard let original else { return nil }
            return Unmanaged.passUnretained(original)

        case .suppress:
            return nil

        case .emit(let stroke):
            guard let down = Self.keyEvent(key: stroke.key, isDown: true, modifiers: stroke.modifiers),
                  let up = Self.keyEvent(key: stroke.key, isDown: false, modifiers: stroke.modifiers) else {
                return nil
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return nil

        case .remapModifier(let target, let isDown):
            guard let event = Self.remapEvent(
                target: target,
                isDown: isDown,
                currentModifiers: modifierTracker.modifiers
            ) else {
                return nil
            }
            event.post(tap: .cghidEventTap)
            return nil

        case .returnToPreviousContext:
            Task { await contextRuntime.returnToPrevious() }
            return nil

        case .moveFocus(let direction):
            // moveFocus performs a bounded Accessibility walk that can take
            // well over 150ms; it must never run synchronously inside the
            // event-tap callback (that would risk tapDisabledByTimeout).
            // Schedule it on the main actor and return immediately, mirroring
            // the context-activation paths; only the Sendable direction is
            // captured, never the CGEvent.
            Task { focusController.moveFocus(direction) }
            return nil

        case .movePointer(let direction, let fast):
            pointerController.move(
                direction: direction,
                fast: fast,
                isRepeat: isRepeat,
                // CGEvent.timestamp is nanoseconds since system startup
                // (CGEventTimestamp = UInt64); PointerMotionState expects
                // Double seconds (design spec §6), so convert explicitly.
                timestamp: TimeInterval(original?.timestamp ?? 0) / 1_000_000_000
            )
            return nil

        case .clickPointer(let count):
            pointerController.click(count)
            return nil

        case .launchApplication(let bundleIdentifier):
            Task { await contextRuntime.activateApplication(bundleIdentifier: bundleIdentifier) }
            return nil

        case .togglePause:
            togglePause()
            return nil
        }
    }

    // MARK: - Synthetic output

    /// A marked keyboard down/up event carrying the requested aggregate
    /// flags, or nil when the event cannot be created.
    private static func keyEvent(
        key: PhysicalKey,
        isDown: Bool,
        modifiers: KeyModifiers
    ) -> CGEvent? {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: key.rawCode,
            keyDown: isDown
        ) else { return nil }
        event.flags = aggregateFlags(for: modifiers)
        event.setIntegerValueField(.eventSourceUserData, value: SyntheticEventMarker.value)
        return event
    }

    /// One marked flagsChanged event for the remapped modifier side: the
    /// physical left Control is replaced by left Command while every other
    /// physical modifier is preserved (design spec §3.3). The release path
    /// removes the target Command only when it is not physically held, so a
    /// real left Command held during the Control release survives.
    private static func remapEvent(
        target: PhysicalKey,
        isDown: Bool,
        currentModifiers: KeyModifiers
    ) -> CGEvent? {
        var modifiers = currentModifiers
        modifiers.remove(.leftControl)
        if isDown {
            modifiers.insert(.leftCommand)
        } else if !currentModifiers.contains(.leftCommand) {
            modifiers.remove(.leftCommand)
        }
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: target.rawCode,
            keyDown: isDown
        ) else { return nil }
        event.type = .flagsChanged
        event.flags = aggregateFlags(for: modifiers)
        event.setIntegerValueField(.eventSourceUserData, value: SyntheticEventMarker.value)
        return event
    }

    // MARK: - Modifier mapping

    /// The aggregate CGEventFlags family for a physical modifier key, or nil
    /// when the key is not a tracked modifier.
    private static func aggregateFlag(for key: PhysicalKey) -> CGEventFlags? {
        switch key {
        case .leftControl, .rightControl:
            return .maskControl
        case .leftCommand, .rightCommand:
            return .maskCommand
        case .leftOption, .rightOption:
            return .maskAlternate
        case .leftShift, .rightShift:
            return .maskShift
        default:
            return nil
        }
    }

    /// The aggregate CGEventFlags for a KeyModifiers value.
    private static func aggregateFlags(for modifiers: KeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.control { flags.insert(.maskControl) }
        if modifiers.command { flags.insert(.maskCommand) }
        if modifiers.option { flags.insert(.maskAlternate) }
        if modifiers.shift { flags.insert(.maskShift) }
        return flags
    }

    // MARK: - Context

    /// The frontmost context the router sees, from the context runtime's
    /// observed history.
    private func frontmostContext() -> FrontmostContext {
        FrontmostContext(bundleIdentifier: contextRuntime.contextHistory.current?.bundleIdentifier)
    }

    // MARK: - Pause

    /// Flips the pause state exactly once and resets transient state.
    /// Invokes `onPauseStateChange` with the new state.
    private func togglePause() {
        isPaused.toggle()
        resetTransientState()
        onPauseStateChange?(isPaused)
    }

    // MARK: - Transient reset

    /// Resets every piece of transient state: the router (Caps down, chord
    /// flag, suppressed key/modifier releases), the modifier tracker,
    /// pointer acceleration, the raw Caps dedup state, and engine-side
    /// manual key suppressions (design spec §7, §8, §10). Called on stop,
    /// tap disable, and every pause transition; the keyDown handlers that
    /// need a suppression to survive a pause transition re-insert it after
    /// this reset.
    private func resetTransientState() {
        _ = router.route(
            InputEvent(
                key: .caps,
                modifiers: [],
                isSynthetic: false,
                kind: .lifecycleReset
            ),
            frontmost: FrontmostContext(bundleIdentifier: nil)
        )
        modifierTracker.reset()
        pointerController.resetMotion()
        lastRawCapsState = nil
        manualSuppressedKeys.removeAll()
    }
}
