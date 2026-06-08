import os

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

    func loadCamerasAndMicrophones() {
        let cameraAuthorized = self.permissions.cameraStatus == .authorized
        let micAuthorized = self.permissions.microphoneStatus == .authorized

        let foundCameras = self.discoverCameras(cameraAuthorized)
        self.cameras = foundCameras
        // Auto-select first camera
        if let first = foundCameras.first {
            self.selectedCameraID = first.uniqueID
        }

        let foundMics = self.discoverMicrophones(micAuthorized)
        self.microphones = foundMics
        // Do NOT auto-select microphone (spec: no mic auto-select)

        mainViewModelLogger.info(
            "Capture devices loaded — cameras: \(foundCameras.count), mics: \(foundMics.count)"
        )
    }
}

// MARK: - MainViewModel — Checklist

extension MainViewModel {
    /// Builds the recording checklist from currently selected devices.
    ///
    /// Delegates name resolution to `cameraLabel(for:)` / `microphoneLabel(for:)`.
    func buildChecklist(display: Display) -> RecordingChecklist {
        let screenDesc = self.displayLabel(for: display)

        var cameraDesc: String?
        if let camera = self.selectedCamera {
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
