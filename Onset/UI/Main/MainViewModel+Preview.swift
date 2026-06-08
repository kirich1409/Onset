import os

// MARK: - Preview park constants

/// Module-level constants for `MainViewModel` preview management to satisfy `no_magic_numbers`.
/// Extracted outside the class because `nonisolated` static lets are not available
/// directly inside `@Observable` classes without `@ObservationIgnored`.
private enum MainViewModelPreviewConstants {
    // Interval for the preview-park loop. The loop is always cancelled quickly;
    // a long sleep keeps timer overhead negligible while yielding to the scheduler.
    // swiftlint:disable:next no_magic_numbers
    static let previewParkInterval: Duration = .seconds(60)

    /// Parks the current task until it is cancelled, yielding every `previewParkInterval`.
    ///
    /// Call from `managePreview` to hold the preview alive while the selected camera
    /// doesn't change. The `.task(id:)` cancels this when the selection changes.
    static func parkUntilCancelled() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: self.previewParkInterval)
        }
    }
}

// MARK: - MainViewModel — Preview lifecycle

extension MainViewModel {
    /// Manages the camera preview for `cameraID`. Call via `.task(id: activeCamera?.uniqueID)`.
    ///
    /// Stops any existing `previewSource` first (device contention), then creates, starts,
    /// and exposes the new source's `SessionHandle`. On cancellation (camera deselected or
    /// view disappears), stops the source and clears the handle.
    func managePreview(for cameraID: String?) async {
        await self.stopCurrentPreview()

        guard let cameraID,
              let camera = self.cameras.first(where: { $0.uniqueID == cameraID })
        else {
            self.previewGeneration += 1
            return
        }

        guard let source = await self.buildAndStartPreview(for: camera) else { return }

        // Park until cancelled (view disappears or camera selection changes).
        await MainViewModelPreviewConstants.parkUntilCancelled()

        // Teardown on cancellation
        await source.stop()
        if self.previewSource === source {
            self.previewSource = nil
            self.previewHandle = nil
            self.previewGeneration += 1
        }
        mainViewModelLogger.debug("Camera preview stopped")
    }

    /// Stops the current preview source (if any) and clears handles.
    func stopCurrentPreview() async {
        guard let old = self.previewSource else { return }
        await old.stop()
        self.previewSource = nil
        self.previewHandle = nil
    }

    /// Creates, starts, and exposes a camera preview source.
    /// Returns the started source, or `nil` when setup fails (increments `previewGeneration`).
    func buildAndStartPreview(for camera: CameraDevice) async -> CameraSource? {
        let format: CameraFormat
        do {
            format = try CameraFormatSelector.pickBestFormat(
                from: camera.formats,
                minFps: Double(RecordingConfiguration.mvpDefault.minCameraFps)
            )
        } catch {
            mainViewModelLogger.warning("No suitable camera format for preview — showing placeholder")
            self.previewGeneration += 1
            return nil
        }

        let source = self.makeCameraSource(camera, format, nil, .mvpDefault)
        self.previewSource = source

        do {
            try await source.start(anchoredTo: HostTimeAnchor.now())
        } catch {
            mainViewModelLogger.warning("Camera preview start failed — showing placeholder")
            self.previewSource = nil
            self.previewGeneration += 1
            return nil
        }

        self.previewHandle = await source.sessionHandle()
        self.previewGeneration += 1
        mainViewModelLogger.debug("Camera preview started")
        return source
    }
}
