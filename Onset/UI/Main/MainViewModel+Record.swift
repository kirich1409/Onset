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

        guard self.validateRecordGuards() else { return }
        guard let display = self.validateDisplaySelection() else { return }

        let resolvedCameraFormat: CameraFormat?
        do {
            resolvedCameraFormat = try self.resolveCameraFormat()
        } catch {
            return
        }

        await self.startRecording(display: display, cameraFormat: resolvedCameraFormat)
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

    /// Resolves the camera format for the selected camera. Returns `nil` for no camera.
    /// Throws and sets `recordError` when the camera has no suitable format.
    func resolveCameraFormat() throws -> CameraFormat? {
        guard let camera = self.selectedCamera else { return nil }
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
        let plan = CapabilityResolver.resolveStartProfile(
            display: display,
            cameraFormat: cameraFormat,
            config: .mvpDefault
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
            cameraDevice: self.selectedCamera,
            cameraFormat: cameraFormat,
            micDevice: self.selectedMic,
            permissions: self.permissions.effectivePermissions,
            checklist: self.buildChecklist(display: display),
            origin: .main
        )

        do {
            try await self.coordinator.start(request)
            mainViewModelLogger.info("Recording started successfully")
        } catch {
            self.recordError = "Не удалось начать запись: \(error)"
            mainViewModelLogger.error("Recording start failed: \(String(describing: error))")
        }
    }
}
