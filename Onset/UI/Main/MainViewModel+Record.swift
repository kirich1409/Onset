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
        let resolvedCameraTargetFps: Int
        do {
            (resolvedCameraFormat, resolvedCameraTargetFps) = try self.resolveCameraFormat()
        } catch {
            return
        }

        await self.startRecording(
            display: display,
            cameraFormat: resolvedCameraFormat,
            cameraModeTargetFps: resolvedCameraTargetFps
        )
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

    /// Resolves the camera format and target fps for the active camera.
    ///
    /// Returns `(nil, 0)` when camera is disabled or no camera is selected.
    /// Throws and sets `recordError` when the camera has no suitable format.
    func resolveCameraFormat() throws -> (format: CameraFormat?, targetFps: Int) {
        guard let camera = self.activeCamera else { return (nil, 0) }
        do {
            let (format, fps) = try CameraFormatSelector.resolveFormat(
                from: camera.formats,
                override: self.selectedCameraMode,
                config: RecordingConfiguration.mvpDefault
            )
            return (format, fps)
        } catch {
            self.recordError = "Не удалось выбрать формат камеры"
            mainViewModelLogger.error(
                "Camera format selection failed: \(String(describing: error))"
            )
            throw error
        }
    }

    /// Stops preview, builds the request, and calls `coordinator.start`.
    func startRecording(display: Display, cameraFormat: CameraFormat?, cameraModeTargetFps: Int) async {
        let plan = CapabilityResolver.resolveStartProfile(
            display: display,
            cameraFormat: cameraFormat,
            cameraTargetFps: cameraFormat != nil ? cameraModeTargetFps : nil,
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
            cameraDevice: self.activeCamera,
            cameraFormat: cameraFormat,
            cameraModeTargetFps: cameraModeTargetFps,
            micDevice: self.selectedMic,
            permissions: self.permissions.effectivePermissions,
            checklist: self.buildChecklist(display: display),
            origin: .main
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
