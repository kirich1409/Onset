import os

// MARK: - MainViewModel — Record action

extension MainViewModel {
    /// Validates guards, resolves devices, and calls `coordinator.start`.
    ///
    /// AC-2 guards are re-checked defensively even though the button should be disabled.
    /// Camera-only (no screen) is deferred post-MVP (decision B, issue #61).
    func record() async {
        guard !self.isStartingRecording else { return }
        self.isStartingRecording = true
        defer { self.isStartingRecording = false }
        self.recordError = nil
        self.outputDirectoryError = nil

        guard self.validateRecordGuards() else { return }
        guard self.validateOutputDirectory() else { return }
        guard let display = self.validateDisplaySelection() else { return }

        let resolvedCameraFormat: CameraFormat?
        do {
            resolvedCameraFormat = try self.resolveCameraFormat()
        } catch {
            return
        }

        await self.startRecording(display: display, cameraFormat: resolvedCameraFormat)
    }

    /// Validates the output directory. Returns `true` when recording may proceed,
    /// `false` when `outputDirectoryError` has been set and start must be aborted.
    ///
    /// A missing or non-writable base directory is a hard stop: there is no silent fallback.
    /// Errors are surfaced as a modal alert (not a footer caption) because the ВЫВОД section
    /// is visually distant from the Record button — see `MainView` for the alert binding.
    func validateOutputDirectory() -> Bool {
        let verdict = OutputDirectoryNaming.validateBaseDirectory(self.outputDirectoryURL)
        switch verdict {
        case .ok:
            return true

        case .doesNotExist:
            self.outputDirectoryError =
                "Папка для записи не найдена. Выберите другую папку или создайте её."
            mainViewModelLogger.error("Output directory does not exist")
            return false

        case .notWritable:
            self.outputDirectoryError =
                "Нет прав на запись в выбранную папку. Выберите другую папку."
            mainViewModelLogger.error("Output directory is not writable")
            return false
        }
    }

    /// Validates AC-2 guards. Returns `true` when recording may proceed, `false` if an error was set.
    func validateRecordGuards() -> Bool {
        // AC-2(d): screen permission required — should be showing empty state, not calling record()
        guard self.permissions.screenStatus == .authorized else {
            mainViewModelLogger.warning("record() called without screen permission — ignoring")
            return false
        }
        guard self.canRecord else {
            if self.isMicAvailableButUnselected {
                self.recordError = "Выберите аудио-вход, чтобы начать запись"
            }
            return false
        }
        return true
    }

    /// Resolves and validates the selected display. Returns `nil` if an error was set.
    ///
    /// `hasVideoSource` already requires screen permission + `selectedDisplayID != nil`, so this
    /// guard is a defensive backstop — reached only if state mutates between `canRecord` check
    /// and this call.
    func validateDisplaySelection() -> Display? {
        guard let display = self.selectedDisplay else {
            self.recordError = "Выберите дисплей для записи экрана"
            return nil
        }
        return display
    }

    /// Resolves the camera format for the active camera. Returns `nil` when camera is disabled
    /// or no camera is selected. Throws and sets `recordError` when the camera has no suitable format.
    func resolveCameraFormat() throws -> CameraFormat? {
        guard let camera = self.activeCamera else { return nil }
        do {
            return try CameraFormatSelector.pickBestFormat(
                from: camera.formats,
                minFps: Double(RecordingConfiguration.mvpDefault.minCameraFps)
            )
        } catch {
            self.recordError = "Не удалось выбрать формат камеры"
            mainViewModelLogger.error(
                "Camera format selection failed: \(String(describing: error))"
            )
            throw error
        }
    }

    /// Stops preview, builds the request, and calls `coordinator.start`.
    func startRecording(display: Display, cameraFormat: CameraFormat?) async {
        // Build config with the user-selected (or default) base output directory (#225).
        let config = RecordingConfiguration.makeMVPDefault(baseDirectory: self.outputDirectoryURL)
        let plan = CapabilityResolver.resolveStartProfile(
            display: display,
            cameraFormat: cameraFormat,
            config: config
        )

        // Stop preview source before starting recording (device contention)
        if let preview = self.previewSource {
            await preview.stop()
            self.previewSource = nil
            self.previewHandle = nil
        }

        let request = RecordingRequest(
            plan: plan,
            display: display,
            cameraDevice: self.activeCamera,
            cameraFormat: cameraFormat,
            micDevice: self.selectedMic,
            permissions: self.permissions.effectivePermissions,
            checklist: self.buildChecklist(display: display),
            origin: .main,
            config: config
        )

        do {
            try await (self.startSessionOverride ?? self.coordinator.start)(request)
            mainViewModelLogger.info("Recording started successfully")
        } catch {
            self.recordError = "Не удалось начать запись: \(error)"
            mainViewModelLogger.error("Recording start failed: \(String(describing: error))")
        }
    }
}
