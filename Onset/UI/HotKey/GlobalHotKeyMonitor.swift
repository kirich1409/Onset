// GlobalHotKeyMonitor.swift
// Onset
//
// Carbon-based system-wide hotkey ⌘⌥⌃R (#67 / AC-9 third stop path).
//
// Carbon's RegisterEventHotKey requires NO Accessibility TCC grant and is NOT deprecated —
// it is the correct macOS API for system-wide hotkeys without permission prompts.
//
// Concurrency: the class is @MainActor (implicit via SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor).
// The Carbon event handler callback is a @convention(c) literal closure (C function pointer) —
// it cannot capture Swift context. `self` is threaded through userData via an Unmanaged
// round-trip. Carbon delivers app-target keyboard events on the main run-loop thread, so
// MainActor.assumeIsolated is the correct hop.

import Carbon.HIToolbox
import os

// MARK: - Logger

nonisolated private let hotKeyLogger = Logger(
    subsystem: "dev.androidbroadcast.Onset",
    category: "GlobalHotKeyMonitor"
)

// MARK: - GlobalHotKeyMonitor

/// Registers and owns the system-wide ⌘⌥⌃R hotkey via Carbon RegisterEventHotKey.
///
/// The monitor is app-lifetime (held as `@State` on `OnsetApp`). Register once from
/// `WindowActionsBridge.onAppear` to bind it to `coordinator.handleHotKey()`.
/// Unregistration happens in `deinit` (or explicitly via `unregister()`).
///
/// `@safe`: the class stores `EventHotKeyRef` and `EventHandlerRef` (opaque C pointers,
/// unsafe types under SWIFT_STRICT_MEMORY_SAFETY). The public interface — `register()`,
/// `unregister()`, `deinit` — encapsulates all pointer arithmetic and Carbon calls behind
/// a safe Swift API. The class is implicitly @MainActor (SWIFT_DEFAULT_ACTOR_ISOLATION).
@safe
final class GlobalHotKeyMonitor {
    // MARK: - Hotkey identity

    /// Numeric ID for this hotkey registration (arbitrary constant, must be > 0).
    /// Carbon uses this to disambiguate multiple registered hotkeys within the process.
    private enum HotKeyID {
        static let signature: OSType = hotKeyFourCharCode("ONST")
        static let id: UInt32 = 1
    }

    // MARK: - Stored C-level handles

    /// The registered hotkey handle returned by `RegisterEventHotKey`. Non-nil after a
    /// successful registration; used to unregister in `unregister()` / `deinit`.
    ///
    /// `nonisolated(unsafe)`: EventHotKeyRef is an OpaquePointer — an unsafe type under
    /// SWIFT_STRICT_MEMORY_SAFETY. Written once from the main thread during `register()`,
    /// read and cleared only in `unregister()` / `deinit` on the same thread.
    nonisolated(unsafe) private var eventHotKeyRef: EventHotKeyRef?

    /// The installed Carbon event handler handle returned by `InstallEventHandler`.
    nonisolated(unsafe) private var eventHandlerRef: EventHandlerRef?

    /// The action invoked (on the main actor) each time the hotkey fires.
    private var handler: (@MainActor () -> Void)?

    // MARK: - Init / deinit

    init() {}

    deinit {
        // deinit is nonisolated in Swift 6. Carbon cleanup functions accept opaque pointers
        // and are thread-safe to call from any thread. The handles were written on the main
        // thread; nil handles make the calls no-ops (guard-checked below).
        // Unregister the hotkey before removing the handler so Carbon can't dispatch an
        // event mid-teardown (Carbon-documented safe teardown order).
        if let ref = unsafe eventHotKeyRef {
            // `unsafe`: UnregisterEventHotKey takes EventHotKeyRef (OpaquePointer).
            unsafe UnregisterEventHotKey(ref)
        }
        if let ref = unsafe eventHandlerRef {
            // `unsafe`: RemoveEventHandler takes EventHandlerRef (OpaquePointer).
            unsafe RemoveEventHandler(ref)
        }
    }

    // MARK: - Internal callback entry point

    /// Called by the @convention(c) callback closure via `MainActor.assumeIsolated`.
    /// Separated from the literal closure body to keep actor-isolated code in the class.
    private func fireHandler() {
        self.handler?()
    }

    // MARK: - Registration

    /// Registers ⌘⌥⌃R as a system-wide hotkey. Idempotent: a second call while already
    /// registered is a no-op (guarded on `eventHotKeyRef != nil`).
    ///
    /// - Parameter handler: Invoked on the main actor each time the hotkey fires.
    func register(handler: @escaping @MainActor () -> Void) {
        // Idempotency guard: RegisterEventHotKey leaks a second registration if called twice.
        // `unsafe`: comparing Optional<OpaquePointer> involves the unsafe OpaquePointer type.
        guard unsafe self.eventHotKeyRef == nil else {
            hotKeyLogger.debug("GlobalHotKeyMonitor.register — already registered, skipping")
            return
        }
        self.handler = handler
        self.installCarbonHandler()
    }

    // MARK: - Unregistration

    /// Explicitly unregisters the hotkey and clears the handler. Idempotent.
    func unregister() {
        // Unregister the hotkey before removing the handler so Carbon can't dispatch an
        // event mid-teardown (Carbon-documented safe teardown order).
        if let ref = unsafe self.eventHotKeyRef {
            // `unsafe`: UnregisterEventHotKey takes EventHotKeyRef (OpaquePointer).
            unsafe UnregisterEventHotKey(ref)
            unsafe self.eventHotKeyRef = nil
        }
        if let ref = unsafe self.eventHandlerRef {
            // `unsafe`: RemoveEventHandler takes EventHandlerRef (OpaquePointer).
            unsafe RemoveEventHandler(ref)
            unsafe self.eventHandlerRef = nil
        }
        self.handler = nil
        hotKeyLogger.info("GlobalHotKeyMonitor: ⌘⌥⌃R unregistered")
    }

    // MARK: - Private Carbon setup

    /// Installs the Carbon event handler and registers the hotkey.
    ///
    /// Extracted from `register()` to stay within the 40-line function-body-length limit
    /// (the @convention(c) literal closure is its own dense block).
    private func installCarbonHandler() {
        // Thread `self` through userData as an unretained Unmanaged pointer.
        // The monitor is app-lifetime (@State on OnsetApp), so the unretained pointer is
        // always valid when a callback fires — no retain cycle, no dangling pointer.
        // `unsafe`: Unmanaged.passUnretained().toOpaque() produces UnsafeMutableRawPointer.
        let userData = unsafe Unmanaged.passUnretained(self).toOpaque()

        // Install a @convention(c) literal closure as the Carbon event handler on the
        // application event target. GetApplicationEventTarget routes events via the main
        // run loop and respects modal-sheet event suppression (preferred over
        // GetEventDispatcherTarget). The @convention(c) closure CANNOT capture Swift
        // context; `self` is recovered from userData via the Unmanaged round-trip.
        //
        // `unsafe` on InstallEventHandler covers:
        // - The @convention(c) closure parameter (C function pointer)
        // - &eventSpec (UnsafeMutablePointer<EventTypeSpec> out-param)
        // - userData (UnsafeMutableRawPointer)
        // - &handlerRef (UnsafeMutablePointer<EventHandlerRef?> out-param)
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handlerRef: EventHandlerRef?
        let installStatus = unsafe InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, rawUserData -> OSStatus in
                // Recover the monitor from the unretained Unmanaged pointer.
                // `unsafe` covers: rawUserData (UnsafeMutableRawPointer?), Unmanaged.fromOpaque,
                // and takeUnretainedValue — all unsafe operations under STRICT_MEMORY_SAFETY.
                guard let rawPtr = unsafe rawUserData else { return OSStatus(eventNotHandledErr) }
                let monitor = unsafe Unmanaged<GlobalHotKeyMonitor>.fromOpaque(rawPtr)
                    .takeUnretainedValue()
                // Carbon delivers app-target hotkey events on the main run-loop thread.
                // assumeIsolated asserts this contract (debug-trap on violation) and avoids
                // a Task allocation on the toggle path.
                MainActor.assumeIsolated { monitor.fireHandler() }
                return noErr
            },
            1,
            &eventSpec,
            userData,
            &handlerRef
        )

        guard installStatus == noErr else {
            hotKeyLogger.error("InstallEventHandler failed: \(installStatus)")
            return
        }
        // `unsafe`: assigning into nonisolated(unsafe) EventHandlerRef? property.
        unsafe self.eventHandlerRef = handlerRef

        // `unsafe`: passing EventHandlerRef? (OpaquePointer?) — an unsafe type.
        unsafe self.registerHotKey(handlerRef: handlerRef)
    }

    /// Calls `RegisterEventHotKey` for ⌘⌥⌃R and stores the result.
    ///
    /// Extracted from `installCarbonHandler()` to keep each function under 40 lines
    /// and isolate the Carbon hotkey registration from the event-handler installation.
    private func registerHotKey(handlerRef: EventHandlerRef?) {
        let hotKeyID = EventHotKeyID(signature: HotKeyID.signature, id: HotKeyID.id)

        // kVK_ANSI_R = 15: Carbon layout-independent virtual key code for the R key.
        // cmdKey | optionKey | controlKey: HIToolbox modifier bit-mask constants.
        var hotKeyRef: EventHotKeyRef?
        // `unsafe`: RegisterEventHotKey writes to EventHotKeyRef? via an out-pointer.
        let status = unsafe RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            UInt32(cmdKey | optionKey | controlKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr else {
            hotKeyLogger.error("RegisterEventHotKey failed: \(status)")
            // Roll back the installed handler to avoid leaking it.
            if let ref = unsafe handlerRef {
                unsafe RemoveEventHandler(ref)
            }
            unsafe self.eventHandlerRef = nil
            return
        }
        // `unsafe`: assigning into nonisolated(unsafe) EventHotKeyRef? property.
        unsafe self.eventHotKeyRef = hotKeyRef
        hotKeyLogger.info("GlobalHotKeyMonitor: ⌘⌥⌃R registered (id=\(HotKeyID.id))")
    }
}

// MARK: - FourCharCode helper

/// Converts a four-character ASCII string literal to an OSType (UInt32) big-endian.
///
/// Carbon's `EventHotKeyID.signature` requires an OSType (four-character code).
/// Swift has no built-in four-char literal; this helper encodes the four UTF-8 bytes
/// of a StaticString as a big-endian UInt32.
nonisolated private func hotKeyFourCharCode(_ string: StaticString) -> OSType {
    // A four-character code is exactly 4 ASCII bytes packed into a big-endian UInt32.
    let fourCharLength = 4
    precondition(string.utf8CodeUnitCount == fourCharLength, "hotKeyFourCharCode requires exactly 4 ASCII characters")
    // Byte-index and shift constants for big-endian UInt32 packing.
    let byte0Shift: UInt32 = 24
    let byte1Shift: UInt32 = 16
    let byte2Shift: UInt32 = 8
    let byte0Index = 0
    let byte1Index = 1
    let byte2Index = 2
    let byte3Index = 3
    // `unsafe` on each subscript: UnsafeBufferPointer<UInt8> element access is unsafe
    // under SWIFT_STRICT_MEMORY_SAFETY = YES. withUTF8Buffer itself is not unsafe.
    return string.withUTF8Buffer { buf in
        (UInt32(unsafe buf[byte0Index]) << byte0Shift)
            | (UInt32(unsafe buf[byte1Index]) << byte1Shift)
            | (UInt32(unsafe buf[byte2Index]) << byte2Shift)
            | UInt32(unsafe buf[byte3Index])
    }
}
