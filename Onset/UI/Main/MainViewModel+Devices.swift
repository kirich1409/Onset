import AVFoundation
import os

// MARK: - Constants

/// Constants for device-change handling, extracted outside the class because
/// `nonisolated` static lets are not available directly inside `@Observable` classes
/// without `@ObservationIgnored`.
private enum MainViewModelDeviceConstants {
    // Debounce before reloading after a device-change event. A lid close fires a burst
    // of KVO + notification events; combined with the stream's `.bufferingNewest(1)`
    // policy this bounds a burst to at most two cheap, idempotent reloads.
    // swiftlint:disable:next no_magic_numbers
    static let deviceChangeDebounce: Duration = .milliseconds(300)
}

// MARK: - MainViewModel — Device loading

extension MainViewModel {
    // MARK: - Load devices

    /// Loads displays, cameras, and microphones in parallel on initial appear.
    ///
    /// - Displays are loaded asynchronously (SCShareableContent).
    /// - Cameras and microphones are loaded synchronously (AVCapture).
    /// - Auto-selects the display when exactly one is found (AC-1).
    /// - Auto-selects the first camera found.
    /// - Does NOT auto-select the microphone (spec).
    func loadDevices() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.loadDisplays()
            }
            group.addTask {
                await MainActor.run {
                    self.loadCamerasAndMicrophones()
                }
            }
        }
    }

    /// Subscribes to display-configuration changes for the lifetime of the caller's structured
    /// task. Should be called once from a `.task` modifier (alongside `loadDevices`);
    /// the task is automatically cancelled — and the subscription torn down — when the view
    /// disappears.
    ///
    /// On each event, re-runs display discovery and applies `DisplaySelectionReconciler` to
    /// preserve or heal the current selection. Also re-evaluates capture devices: the built-in
    /// mic's availability depends on lid state, which changes when the internal display sleeps
    /// (lid closed → `didChangeScreenParametersNotification` fires via `screenChangeEvents()`).
    /// Does NOT debounce: events arrive infrequently (human-scale hardware operations) and
    /// discovery is idempotent.
    func subscribeToDisplayChanges() async {
        for await _ in self.screenChangeEvents() {
            await self.loadDisplays()
            self.loadCamerasAndMicrophones()
        }
    }

    func loadDisplays() async {
        let authorized = self.permissions.screenStatus == .authorized
        do {
            let found = try await self.discoverDisplays(authorized)
            self.applyDisplays(found)
            mainViewModelLogger.info("Displays loaded — count: \(found.count)")
        } catch {
            mainViewModelLogger.error("Display discovery failed: \(String(describing: error))")
            self.displays = []
            self.recordError = "Не удалось загрузить список дисплеев"
        }
    }

    /// Applies a freshly-discovered display list, reconciling the current selection.
    ///
    /// Separated from `loadDisplays()` so `DisplaySelectionReconciler` can be tested
    /// directly without going through the async discovery path.
    ///
    /// - Parameter newDisplays: The complete, up-to-date list from device discovery.
    func applyDisplays(_ newDisplays: [Display]) {
        let outcome = DisplaySelectionReconciler.reconcile(
            selected: self.selectedDisplayID,
            newDisplays: newDisplays
        )
        self.displays = newDisplays
        switch outcome {
        case let .keepExisting(id):
            self.selectedDisplayID = id

        case let .fallbackToFirst(id):
            mainViewModelLogger.info("Selected display gone — falling back to first available")
            self.selectedDisplayID = id

        case let .autoSelectSingle(id):
            // AC-1: exactly one display available; auto-select it.
            self.selectedDisplayID = id

        case .noSelection:
            self.selectedDisplayID = nil
        }
    }

    // Rationale: two parallel resolver switch blocks — splitting would obscure the
    // camera/mic symmetry; logic belongs together in the same function.
    // swiftlint:disable:next function_body_length
    func loadCamerasAndMicrophones() {
        let cameraAuthorized = self.permissions.cameraStatus == .authorized
        let micAuthorized = self.permissions.microphoneStatus == .authorized

        let foundCameras = self.discoverCameras(cameraAuthorized)
        self.cameras = foundCameras
        // Build the name cache once per load so ForEach renders use O(1) dictionary lookups
        // instead of a synchronous AVCaptureDevice(uniqueID:) call per item per render pass.
        self.cameraDisplayNames = Dictionary(
            uniqueKeysWithValues: foundCameras.map { camera in
                (camera.uniqueID, AVCaptureDevice(uniqueID: camera.uniqueID)?.localizedName ?? "Камера")
            }
        )

        let foundMics = self.discoverMicrophones(micAuthorized)
        self.microphones = foundMics
        // Do NOT auto-select microphone (spec: no mic auto-select)

        // Restore saved selections under the guard flag so didSet does not overwrite
        // the just-loaded record. `DeviceSelectionResolver` encodes the invariant that
        // `.disconnected` and auto-selected fallback never coexist: `selectFirstCameraIfNeeded`
        // is called only from the `.noSavedSelection` branch.
        self.isApplyingPersistedSelection = true
        defer { self.isApplyingPersistedSelection = false }

        let store = self.makeStore()

        switch DeviceSelectionResolver.resolveCamera(
            saved: store.loadCamera(),
            availableIDs: foundCameras.map(\.uniqueID)
        ) {
        case .disabled:
            // User explicitly disabled the camera — honour the choice; do NOT auto-select.
            self.cameraEnabled = false
            self.selectedCameraID = nil
            self.disconnectedCameraName = nil
            mainViewModelLogger.debug("Restored camera state — disabled by user")

        case let .restore(id):
            self.cameraEnabled = true
            self.selectedCameraID = id
            self.disconnectedCameraName = nil
            // A selected camera is present this session — arm the live-disconnect announcement (#256).
            self.hasObservedPresentCamera = true
            mainViewModelLogger.debug("Restored camera selection — device present")

        case let .disconnected(name):
            self.cameraEnabled = true
            self.selectedCameraID = nil
            // Edge-trigger on the nil→non-nil transition: loadCamerasAndMicrophones re-runs on every
            // device-change event, so the still-unplugged camera re-enters .disconnected on each
            // reload. Announcing only on the edge prevents VoiceOver spam from unrelated device
            // changes while the camera stays absent (#256).
            let wasConnected = self.disconnectedCameraName == nil
            self.disconnectedCameraName = name
            mainViewModelLogger.info("Saved camera not available — showing disconnected notice")
            // The dominant disconnect flow nils selectedCameraID → preview goes .idle (no announce)
            // and CameraUnavailableRow is silent. Announce explicitly here (the single real
            // live-unplug site); gated so a saved-but-absent camera at launch stays silent (#256).
            let announcement = cameraDisconnectAnnouncement(
                name: name,
                hasObservedPresentCamera: self.hasObservedPresentCamera
            )
            if wasConnected, let announcement {
                Self.postAnnouncement(announcement)
            }

        case .noSavedSelection:
            // First launch or explicitly cleared — apply the first-camera default.
            self.selectFirstCameraIfNeeded()
            // Arm the announcement only if a real camera actually got auto-selected.
            if self.selectedCamera != nil {
                self.hasObservedPresentCamera = true
            }
        }

        switch DeviceSelectionResolver.resolve(
            saved: store.loadMicrophone(),
            availableIDs: foundMics.map(\.uniqueID)
        ) {
        case let .restore(id):
            self.selectedMicID = id
            self.disconnectedMicName = nil
            mainViewModelLogger.debug("Restored microphone selection — device present")

        case let .disconnected(name):
            self.selectedMicID = nil
            self.disconnectedMicName = name
            mainViewModelLogger.info("Saved microphone not available — showing disconnected notice")

        case .noSavedSelection:
            break // mic never auto-selects (spec)
        }

        mainViewModelLogger.info(
            "Capture devices loaded — cameras: \(foundCameras.count), mics: \(foundMics.count)"
        )
    }

    // MARK: - Live device-change observation

    /// Re-runs camera/microphone loading on every device topology change (connect,
    /// disconnect, `isSuspended` flip — e.g. notebook lid closed/opened) while the main
    /// window is open.
    ///
    /// Call after `loadDevices()` from MainView's `.task`; the loop runs until the task
    /// is cancelled (view disappears), which terminates the stream and tears down the
    /// underlying `DeviceAvailabilityObserver` via its `onTermination` hook.
    ///
    /// Reload safety: `loadCamerasAndMicrophones()` is idempotent — repeated runs re-resolve
    /// the persisted selection (`.disconnected` notice when the device vanished, `.restore`
    /// when it came back) without clobbering the saved record.
    func observeDeviceChanges() async {
        for await _ in self.makeDeviceChangeStream() {
            // Coalesce bursts: the sleep absorbs trailing events into the stream's
            // 1-slot buffer, so a burst costs at most two reloads.
            try? await Task.sleep(for: MainViewModelDeviceConstants.deviceChangeDebounce)
            guard !Task.isCancelled else { return }
            self.loadCamerasAndMicrophones()
            mainViewModelLogger.debug("Device change handled — capture device lists reloaded")
        }
    }
}

// MARK: - MainViewModel — Camera persistence

extension MainViewModel {
    /// Persists the current effective camera choice as a tri-state `PersistedCameraSelection`.
    ///
    /// Called from `selectedCameraID.didSet` and `cameraEnabled.didSet` (when not under the
    /// `isApplyingPersistedSelection` guard). Reading both `cameraEnabled` and `selectedCameraID`
    /// in one place ensures the stored value always reflects the user's full intent:
    /// - Camera OFF → `.disabled` (regardless of `selectedCameraID`).
    /// - Camera ON, device selected → `.enabled(record)`.
    /// - Camera ON, no device selected → `clearCamera()` (no selection to persist).
    ///
    /// Never called during restore (`isApplyingPersistedSelection == true` at call sites).
    func persistCameraSelection() {
        let store = self.makeStore()
        guard self.cameraEnabled else {
            store.saveCamera(.disabled)
            return
        }
        if let id = self.selectedCameraID {
            // Resolve the label at persist time — name is PII, stored for UI only, never logged.
            let name = if let device = self.cameras.first(where: { $0.uniqueID == id }) {
                self.cameraLabel(for: device)
            } else {
                "Камера"
            }
            store.saveCamera(.enabled(DeviceSelectionRecord(uniqueID: id, localizedName: name)))
        } else {
            store.clearCamera()
        }
    }
}

// MARK: - MainViewModel — Checklist

extension MainViewModel {
    /// Builds the recording checklist from currently active devices.
    ///
    /// Uses `activeCamera` (not `selectedCamera`) so a disabled camera toggle omits the
    /// camera entry from the checklist. Delegates name resolution to `cameraLabel(for:)` /
    /// `microphoneLabel(for:)`.
    func buildChecklist(display: Display) -> RecordingChecklist {
        let screenDesc = DisplayLabelMapper.recordingScreenLabel(
            pixelWidth: display.pixelWidth,
            pixelHeight: display.pixelHeight,
            refreshHz: display.refreshHz
        )

        var cameraDesc: String?
        if let camera = self.activeCamera {
            let name = self.cameraLabel(for: camera)
            // Intentionally uses the baseline tier (≤1080p): pickBestFormat is called WITHOUT
            // allowAboveFullHD, which defaults to false. Actual recording uses the record tier
            // (4K, allowAboveFullHD: true) via resolveCameraFormat in MainViewModel+Record.swift.
            // The checklist label is an availability hint, not the exact record format — this is
            // accepted behavior, not a bug.
            if let fmt = try? CameraFormatSelector.pickBestFormat(
                from: camera.formats,
                minFps: Double(RecordingConfiguration.mvpDefault.minCameraFps)
            ) {
                cameraDesc = "\(name) · \(fmt.pixelWidth)×\(fmt.pixelHeight)"
            } else {
                cameraDesc = name
            }
        }

        var micDesc: String?
        if let mic = self.selectedMic {
            micDesc = self.microphoneLabel(for: mic)
        }

        return RecordingChecklist(
            screenDescription: screenDesc,
            cameraDescription: cameraDesc,
            microphoneDescription: micDesc
        )
    }
}
