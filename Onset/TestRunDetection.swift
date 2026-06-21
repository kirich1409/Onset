import Foundation

// MARK: - Test-run detection

/// `true` when the process is running as a test host (XCTest or Swift Testing).
///
/// XCTest sets `XCTestConfigurationFilePath` in the environment before executing any test
/// bundle; Swift Testing runs through the same test-host launch path, so this variable is
/// also set under Swift Testing. In production this is always `false`.
///
/// Used to fail-fast on test-only invariants — e.g. a `UserDefaults`-backed store must never
/// bind to `UserDefaults.standard` under a test run, where it would silently poison the
/// developer's real defaults (see `UserDefaultsDeviceSelectionStore` / `UserDefaultsOutputFolderStore`).
/// Also gates app-level UI suppression in `OnsetApp`.
nonisolated let isRunningUnderXCTest =
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
