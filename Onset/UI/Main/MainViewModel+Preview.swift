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
        // Mirror the old unconditional `previewFailed = false` reset: `stopCurrentPreview`
        // sets `.idle` only when there is a live source, but a sticky `.failed` (set with
        // `previewSource == nil`) would otherwise survive re-selection. Reset here so
        // re-selecting a camera clears the error placeholder.
        self.previewState = .idle

        guard let cameraID else {
            // Normal deselect (camera toggle off or no cameras available). State stays `.idle`.
            self.previewGeneration += 1
            return
        }

        guard let camera = self.cameras.first(where: { $0.uniqueID == cameraID }) else {
            // Camera was removed from the available list (hot-unplug race).
            // Selection stays set but no handle can be established — mark as failed
            // so the error placeholder is shown rather than spinning indefinitely.
            mainViewModelLogger.warning("Camera preview skipped — selected device not in available list")
            self.previewState = .failed
            self.previewGeneration += 1
            return
        }

        // Valid camera in hand: enter the connecting state. Set AFTER the guards (not at the
        // top of managePreview) so deselect/hot-unplug never leave `.connecting` without a camera.
        // Bump the attempt id exactly once here, then capture it locally. INVARIANT: no `await`
        // between the bump and the capture, or a re-entrant attempt B could overwrite the id
        // before attempt A captures it (#255).
        self.previewAttempt += 1
        let attempt = self.previewAttempt
        self.previewState = .connecting

        // Compute the threshold BEFORE the task group so `camera` is not captured inside the
        // `@Sendable` child task — only the value-typed `threshold`/`attempt` cross into it (#255).
        let threshold = self.connectTimeout(isContinuity: camera.isContinuityCamera)

        // Structured watchdog: the child runs the soft-connect timer, the main flow builds the
        // preview, then `cancelAll()` tears the watchdog down. The group is scoped to this
        // `.task(id:)`, so a camera switch cancels both. Return type `CameraSource?` is inferred
        // from `return s` (precedent: `+Devices.swift` withTaskGroup).
        let source = await withTaskGroup(of: Void.self) { group -> CameraSource? in
            group.addTask {
                await self.runConnectWatchdog(threshold: threshold, attempt: attempt)
            }
            let built = await self.buildAndStartPreview(for: camera, attempt: attempt)
            group.cancelAll()
            return built
        }

        guard let source else {
            // Build failed: gate so a stale attempt cannot stamp `.failed` over a newer one.
            if attempt == self.previewAttempt {
                self.previewState = .failed
            }
            return
        }

        // Park until cancelled (view disappears or camera selection changes).
        await MainViewModelPreviewConstants.parkUntilCancelled()

        // Teardown on cancellation
        await source.stop()
        if self.previewSource === source {
            self.previewSource = nil
            self.previewState = .idle
            self.previewGeneration += 1
        }
        mainViewModelLogger.debug("Camera preview stopped")
    }

    /// Soft-connect watchdog (#255): after `threshold` elapses, flip a still-`.connecting`
    /// preview to `.connectingSlow`. The connection is NOT cancelled — a late handle still
    /// promotes `.connectingSlow → .live`.
    ///
    /// Gates: `attempt == previewAttempt` rejects a stale watchdog from a previous attempt whose
    /// sleep completed exactly as a camera switch happened (the load-bearing barrier); `if case
    /// .connecting` avoids overwriting an already-arrived `.live`/`.failed`. A thrown
    /// `CancellationError` (structured cancellation via `cancelAll()` / `.task(id:)`) exits silently.
    func runConnectWatchdog(threshold: Duration, attempt: Int) async {
        do {
            try await self.connectSleep(threshold)
        } catch {
            return
        }
        guard attempt == self.previewAttempt, case .connecting = self.previewState else { return }
        self.previewState = .connectingSlow
    }

    /// Stops the current preview source (if any) and clears handles.
    func stopCurrentPreview() async {
        guard let old = self.previewSource else { return }
        await old.stop()
        self.previewSource = nil
        self.previewState = .idle
    }

    /// Creates, starts, and exposes a camera preview source.
    /// Returns the started source, or `nil` when setup fails (increments `previewGeneration`).
    ///
    /// `attempt` gates the `.live`/`.failed` writes so a continuation from a superseded attempt
    /// cannot mutate the current state (#255).
    func buildAndStartPreview(for camera: CameraDevice, attempt: Int) async -> CameraSource? {
        let format: CameraFormat
        do {
            format = try CameraFormatSelector.pickBestFormat(
                from: camera.formats,
                minFps: Double(RecordingConfiguration.mvpDefault.minCameraFps)
            )
        } catch {
            mainViewModelLogger.warning(
                "No suitable camera format for preview — showing placeholder: \(String(describing: error))"
            )
            self.previewGeneration += 1
            return nil
        }

        let source = self.makeCameraSource(camera, format, nil, .mvpDefault)
        // INVARIANT: assign `previewSource` BEFORE the connect await so the identity gate below
        // (and the teardown guard) can compare against the in-flight source.
        self.previewSource = source

        let handle: SessionHandle?
        do {
            handle = try await self.startPreviewSource(source)
        } catch {
            mainViewModelLogger.warning(
                "Camera preview start failed — showing placeholder: \(String(describing: error))"
            )
            self.previewSource = nil
            self.previewGeneration += 1
            return nil
        }

        // Gate `.live` by BOTH identity (`previewSource === source`) — a suspended `start()` of
        // camera A resuming after a switch to B has `previewSource === sourceB ≠ sourceA` — AND
        // `attempt == previewAttempt` (closes the narrow window where identity would otherwise
        // rely on undeclared continuation FIFO order on the `CameraSource` actor). Late-handle
        // promotion (`.connectingSlow → .live`) still passes: the slow-but-no-switch path does
        // not bump a new attempt, so both gates hold.
        if let handle, self.previewSource === source, attempt == self.previewAttempt {
            self.previewState = .live(handle)
        }
        self.previewGeneration += 1
        mainViewModelLogger.debug("Camera preview started")
        return source
    }
}
