import os

// MARK: - Constants

/// Constants for device-change handling, extracted outside the class because
/// `nonisolated` static lets are not available directly inside `@Observable` classes
/// without `@ObservationIgnored`.
private enum MainViewModelDeviceConstants {
    /// Debounce before reloading after a device-change event. A lid close fires a burst
    /// of KVO + notification events; combined with the stream's `.bufferingNewest(1)`
    /// policy this bounds a burst to at most two cheap, idempotent reloads.
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

    func loadDisplays() async {
        let authorized = self.permissions.screenStatus == .authorized
        do {
            let found = try await self.discoverDisplays(authorized)
            self.displays = found
            // AC-1: auto-select when exactly one display
            if found.count == 1 {
                self.selectedDisplayID = found[0].displayID
            }
            mainViewModelLogger.info("Displays loaded — count: \(found.count)")
        } catch {
            mainViewModelLogger.error("Display discovery failed: \(String(describing: error))")
            self.displays = []
            self.recordError = "Не удалось загрузить список дисплеев"
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
            mainViewModelLogger.debug("Restored camera selection — device present")

        case let .disconnected(name):
            self.cameraEnabled = true
            self.selectedCameraID = nil
            self.disconnectedCameraName = name
            mainViewModelLogger.info("Saved camera not available — showing disconnected notice")

        case .noSavedSelection:
            // First launch or explicitly cleared — apply the first-camera default.
            self.selectFirstCameraIfNeeded()
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
