// AppVersionFormatterTests.swift
// OnsetTests
//
// Swift Testing suite for AppVersionFormatter (#166).
//
// Tests the pure static formatter `AppVersionFormatter.versionDisplay(short:build:)`.
// No Bundle or system access — all inputs are synthetic strings, making these fast L2 tests.
//
@testable import Onset
import Testing

// MARK: - Normal inputs

@Suite("AppVersionFormatter — normal inputs")
struct AppVersionFormatterNormalTests {
    @Test("short and build both present produces 'X.Y.Z (N)' form")
    func bothPresent() {
        let result = AppVersionFormatter.versionDisplay(short: "0.1.0", build: "1")
        #expect(result == "0.1.0 (1)")
    }

    @Test("larger build number is preserved verbatim")
    func largeBuildNumber() {
        let result = AppVersionFormatter.versionDisplay(short: "1.2.3", build: "4567")
        #expect(result == "1.2.3 (4567)")
    }
}

// MARK: - Missing components

@Suite("AppVersionFormatter — missing components")
struct AppVersionFormatterMissingTests {
    @Test("empty build returns short version only")
    func emptyBuild() {
        let result = AppVersionFormatter.versionDisplay(short: "0.1.0", build: "")
        #expect(result == "0.1.0")
    }

    @Test("empty short returns build number only")
    func emptyShort() {
        let result = AppVersionFormatter.versionDisplay(short: "", build: "42")
        #expect(result == "42")
    }

    @Test("both empty returns em-dash fallback")
    func bothEmpty() {
        let result = AppVersionFormatter.versionDisplay(short: "", build: "")
        #expect(result == "—")
    }
}

// MARK: - Whitespace trimming

@Suite("AppVersionFormatter — whitespace trimming")
struct AppVersionFormatterWhitespaceTests {
    @Test("leading and trailing whitespace is stripped before formatting")
    func whitespaceIsStripped() {
        let result = AppVersionFormatter.versionDisplay(short: "  0.1.0  ", build: "  1  ")
        #expect(result == "0.1.0 (1)")
    }

    @Test("whitespace-only short is treated as empty")
    func whitespaceOnlyShort() {
        let result = AppVersionFormatter.versionDisplay(short: "   ", build: "7")
        #expect(result == "7")
    }

    @Test("whitespace-only build is treated as empty")
    func whitespaceOnlyBuild() {
        let result = AppVersionFormatter.versionDisplay(short: "0.2.0", build: "  ")
        #expect(result == "0.2.0")
    }
}
