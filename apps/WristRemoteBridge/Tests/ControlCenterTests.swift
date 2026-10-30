import AVFoundation
import Foundation
import XCTest
@testable import WristRemoteBridge

@MainActor
final class ControlCenterTests: XCTestCase {
    func testPreviewAudioSettingsUseOnlyTheInjectedDefaults() throws {
        let suiteName = "wristremote.preview.test." + UUID().uuidString
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let key = "WristRemote.liveAudioOutputUID"
        let original = UserDefaults.standard.string(forKey: key)
        let model = BridgeAppModel(preferences: BridgePreferences(defaults: suite, trustedIdentityStore: TestPreviewIdentityStore()),
                                   isPresentationPreview: true, audioDefaults: suite)
        model.selectedAudioOutputUID = "preview-device"
        XCTAssertEqual(suite.string(forKey: key), "preview-device")
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), original)
    }

    func testDeniedPermissionNeverPostsAnyInput() {
        var posts = 0
        let engine = MacControlEngine(dependencies: .init(trusted: { false },
            pointer: { _, _ in posts += 1; return true }, click: { _ in posts += 1; return true },
            scroll: { _, _ in posts += 1; return true }, mediaKey: { _ in posts += 1; return true },
            binding: { _ in posts += 1; return true }))
        for action in MacControlEngine.actions {
            XCTAssertFalse(engine.perform(.init(action: action)).accepted)
        }
        XCTAssertEqual(posts, 0)
    }

    func testMacRoutesPointerClickScrollAndMediaWithoutHoldingKeys() {
        var events: [String] = []
        let engine = MacControlEngine(dependencies: .init(trusted: { true },
            pointer: { x, y in events.append("move:\(x):\(y)"); return true },
            click: { secondary in events.append(secondary ? "secondary" : "click"); return true },
            scroll: { _, _ in events.append("scroll"); return true },
            mediaKey: { key in events.append("media:\(key)"); return true },
            binding: { binding in events.append(binding.action.rawValue); return true }))
        XCTAssertTrue(engine.perform(.init(action: .pointer, x: 20, y: -10)).accepted)
        XCTAssertTrue(engine.perform(.init(action: .secondaryClick)).accepted)
        XCTAssertTrue(engine.perform(.init(action: .scroll, y: 20)).accepted)
        XCTAssertTrue(engine.perform(.init(action: .nextTrack)).accepted)
        XCTAssertTrue(engine.perform(.init(action: .nextPage)).accepted)
        XCTAssertEqual(events, ["move:20.0:-10.0", "secondary", "scroll", "media:17", "arrowRight"])
        XCTAssertFalse(engine.perform(.init(targetID: "tv-123", action: .click)).accepted)
        XCTAssertFalse(engine.perform(.init(action: .click, issuedAt: 1)).accepted)
        XCTAssertEqual(events.count, 5)
    }

    func testRecordingStreamsSmallAACWithoutWAVAndCancellationRemovesPartialFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = WristRecordingLibrary(directory: root)
        let id = UUID()
        XCTAssertTrue(try library.start(id: id))
        let samples = (0..<16_000).map { Int16(sin(Double($0) * 2 * .pi * 440 / 16_000) * 8_000) }
        for _ in 0..<60 { XCTAssertTrue(library.append(samples, id: id)) }
        let pending = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.pathExtension, "m4a")
        let file = try library.finish(id: id)
        XCTAssertEqual(file.pathExtension, "m4a")
        let decoded = try AVAudioFile(forReading: file)
        XCTAssertEqual(decoded.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(decoded.fileFormat.channelCount, 1)
        XCTAssertEqual(decoded.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(decoded.length, 960_000, accuracy: 1_024)
        let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        XCTAssertLessThan(bytes, 150_000, "One minute must stay near the 120 KB target")
        let evidence = XCTAttachment(string: "AAC-LC in M4A, mono 16000 Hz, 16000 bps, 60 seconds, \(bytes) bytes; no WAV files")
        evidence.name = "aac-size-validation"; evidence.lifetime = .keepAlways; add(evidence)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 16_000))
        try decoded.read(into: buffer)
        XCTAssertGreaterThan(buffer.frameLength, 0)
        let channel = try XCTUnwrap(buffer.floatChannelData?.pointee)
        XCTAssertTrue((0..<Int(buffer.frameLength)).contains { abs(channel[$0]) > 0.05 }, "AAC must decode to non-silent audio")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        let cancelled = UUID(); XCTAssertTrue(try library.start(id: cancelled))
        XCTAssertTrue(library.append([1, 2, 3], id: cancelled))
        library.cancel(id: cancelled)
        XCTAssertFalse(library.append([1], id: cancelled))
        XCTAssertThrowsError(try library.finish(id: cancelled))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "m4a" }.count, 1)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".wav") || $0.contains("partial") })
    }

    func testRecordingRestoresPrivatePermissionsOnExistingDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = WristRecordingLibrary(directory: root)
        let id = UUID()
        XCTAssertTrue(try library.start(id: id))
        let permissions = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
        library.cancel(id: id)
    }

    func testRecordingRejectsExistingFileWithoutDeletingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let existing = root.appendingPathComponent(".Wrist-\(id.uuidString).partial.m4a")
        try Data("existing".utf8).write(to: existing)
        XCTAssertThrowsError(try WristRecordingLibrary(directory: root).start(id: id))
        XCTAssertEqual(try Data(contentsOf: existing), Data("existing".utf8))
    }

    func testLiveAudioBacklogRejectsDelayAndOldSessionCompletions() throws {
        let budget = WristAudioBacklog(maximumFrames: 100)
        let old = try XCTUnwrap(budget.reserve(60))
        XCTAssertNil(budget.reserve(41))
        budget.reset()
        _ = try XCTUnwrap(budget.reserve(70))
        budget.complete(60, generation: old)
        XCTAssertNil(budget.reserve(31), "A callback from an old stream must not free a new stream's budget")
        XCTAssertNotNil(budget.reserve(30))
    }

    func testNativeDictationRequiresDedicatedDuplexDeviceShortcutAndForegroundCodex() {
        let dedicated = WristAudioOutputDevice(id: "separate", name: "Dedicated", deviceID: 42, hasInput: true)
        let outputOnly = WristAudioOutputDevice(id: "output", name: "Output only", deviceID: 43, hasInput: false)
        let protected = WristAudioOutputDevice(id: "protected", name: "BlackHole 2ch", deviceID: 44, hasInput: true)
        XCTAssertFalse(WristNativeDictationPolicy.permits(device: dedicated, wirelessOutputUID: "old", shortcutConfigured: true, codexFrontmost: true), "Unverified dictation must not start even with a configured device")
        XCTAssertFalse(WristNativeDictationPolicy.permits(device: nil, wirelessOutputUID: "old", shortcutConfigured: true, codexFrontmost: true))
        XCTAssertFalse(WristNativeDictationPolicy.permits(device: dedicated, wirelessOutputUID: "separate", shortcutConfigured: true, codexFrontmost: true))
        XCTAssertFalse(WristNativeDictationPolicy.permits(device: protected, wirelessOutputUID: "old", shortcutConfigured: true, codexFrontmost: true))
        XCTAssertFalse(WristNativeDictationPolicy.permits(device: outputOnly, wirelessOutputUID: "old", shortcutConfigured: true, codexFrontmost: true))
        XCTAssertFalse(WristNativeDictationPolicy.permits(device: dedicated, wirelessOutputUID: "old", shortcutConfigured: false, codexFrontmost: true))
        XCTAssertFalse(WristNativeDictationPolicy.permits(device: dedicated, wirelessOutputUID: "old", shortcutConfigured: true, codexFrontmost: false))
    }

    func testSharedBlackHoleIsNeverOfferedOrOpenedForWatchAudio() {
        let byUID = WristAudioOutputDevice(id: "BlackHole2ch_UID", name: "Renamed", deviceID: 45, hasInput: true)
        let byName = WristAudioOutputDevice(id: "other", name: "BlackHole 2ch", deviceID: 46, hasInput: true)
        let independent = WristAudioOutputDevice(id: "independent", name: "Independent", deviceID: 47, hasInput: true)
        XCTAssertTrue(byUID.isProtectedSharedDevice)
        XCTAssertTrue(byName.isProtectedSharedDevice)
        XCTAssertFalse(independent.isProtectedSharedDevice)
        XCTAssertFalse(WristNativeDictationPolicy.permits(device: byUID, wirelessOutputUID: "old", shortcutConfigured: true, codexFrontmost: true))
        XCTAssertFalse(WristAudioOutputDevice.selectableOutputs().contains { $0.isProtectedSharedDevice })

        // A saved BlackHole selection is refused before any audio engine opens it.
        let output = WristLiveAudioOutput()
        XCTAssertThrowsError(try output.start(deviceUID: "BlackHole2ch_UID")) { error in
            if WristAudioOutputDevice.virtualOutputs().contains(where: { $0.id == "BlackHole2ch_UID" }) {
                XCTAssertEqual(error as? WristLiveAudioOutput.OutputError, .protectedDevice)
            }
        }
        XCTAssertFalse(output.append([1, 2, 3]))
        output.stop()
    }

    func testMissingVirtualDeviceFailsWithoutStartingOrChangingSystemOutput() {
        let output = WristLiveAudioOutput()
        XCTAssertThrowsError(try output.start(deviceUID: "nonexistent-test-device"))
        XCTAssertFalse(output.append([1, 2, 3]))
        output.stop()
    }

    func testTelevisionUsesOnlyFixedArgumentsAndReportsDisconnect() async {
        var calls: [[String]] = []
        var fail = false
        let tv = WristTelevisionAdapter { _, arguments in
            calls.append(arguments)
            return .init(status: fail ? 1 : 0, output: arguments.last == "get-state" ? "device\n" : "connected")
        }
        let configuration = WristTelevisionConfiguration(name: "Test TV", address: "192.168.10.20:5555", executablePath: "/test/adb")
        await tv.connect(configuration)
        XCTAssertTrue(tv.isConnected)
        let target = tv.target!
        let accepted = await tv.perform(.init(targetID: target.id, action: .up))
        XCTAssertTrue(accepted.accepted)
        XCTAssertEqual(calls.last, ["-s", "192.168.10.20:5555", "shell", "input", "keyevent", "19"])
        let unsupported = await tv.perform(.init(targetID: target.id, action: .pointer))
        XCTAssertFalse(unsupported.accepted); XCTAssertEqual(calls.count, 3)
        fail = true
        let failed = await tv.perform(.init(targetID: target.id, action: .select))
        XCTAssertFalse(failed.accepted); XCTAssertNil(tv.target)
    }

    func testInvalidTelevisionReconnectDiscardsPreviousTarget() async {
        let tv = WristTelevisionAdapter { _, arguments in
            .init(status: 0, output: arguments.last == "get-state" ? "device\n" : "connected")
        }
        await tv.connect(.init(name: "First", address: "192.168.10.20:5555", executablePath: "/test/adb"))
        XCTAssertNotNil(tv.target)
        await tv.connect(.init(name: "Invalid", address: "not-a-local-address", executablePath: "/test/adb"))
        XCTAssertNil(tv.target)
        XCTAssertFalse(tv.isConnected)
    }

    func testTVRejectsPublicAddressesAndInjectionBeforeRunner() async {
        var calls = 0
        let tv = WristTelevisionAdapter { _, _ in calls += 1; return .init(status: 0, output: "device") }
        for address in ["8.8.8.8:5555", "192.168.1.2:5555;reboot", "localhost:5555", "192.168.1.2:0"] {
            await tv.connect(.init(name: "TV", address: address, executablePath: "/test/adb"))
        }
        XCTAssertEqual(calls, 0)
    }
}

private struct TestPreviewIdentityStore: TrustedIdentityFingerprintStoring {
    func load() -> TrustedIdentityFingerprintLoadResult { .loaded([]) }
    func save(_ fingerprints: Set<String>) -> Bool { false }
}
