import Testing
import Foundation
@testable import Rift

@MainActor
struct PlayerStateTests {
    let state = PlayerState()

    @Test func formattedTime() {
        #expect(state.formattedTime(0) == "00:00")
        #expect(state.formattedTime(65) == "01:05")
        #expect(state.formattedTime(3661) == "01:01:01")
        #expect(state.formattedTime(-5) == "00:00")
        #expect(state.formattedTime(Double.nan) == "00:00")
        #expect(state.formattedTime(Double.infinity) == "00:00")
    }

    @Test func formattedTimeHours() {
        #expect(state.formattedTime(3600) == "01:00:00")
        #expect(state.formattedTime(86399) == "23:59:59")
    }

    @Test func volumeClamping() {
        state.setVolume(1.5)
        #expect(state.volume == 1.0)
        state.setVolume(-0.5)
        #expect(state.volume == 0.0)
        state.setVolume(0.5)
        #expect(state.volume == 0.5)
    }

    @Test func seekNoVideo() {
        state.seek(to: 30)
        #expect(state.currentTime == 30) // seek sets time regardless of video loaded
    }
}

@MainActor
struct FileValidationTests {
    @Test func mp4Signature() throws {
        // 16 bytes: ISO Base Media File Format (ftypisom)
        var bytes = Data([0x00, 0x00, 0x00, 0x1C, 0x66, 0x74, 0x79, 0x70])
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 8))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-sig.mp4")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(PlayerState.isValidVideoFile(url))
    }

    @Test func invalidSignature() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-sig.txt")
        try Data("not a video file".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!PlayerState.isValidVideoFile(url))
    }

    @Test func emptyFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-empty")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!PlayerState.isValidVideoFile(url))
    }
}

struct ResourceLocatorTests {
    @Test func macOSBundleResourceRootAndFlatCompatibility() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = root.appendingPathComponent("Rift_Rift.bundle", isDirectory: true)
        let resourcesURL = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.rift.tests.resources",
            "CFBundleName": "Rift_Rift",
            "CFBundlePackageType": "BNDL"
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        defer { try? FileManager.default.removeItem(at: root) }

        let roots = ResourceLocator.resourceBundleRoots(under: root)
        let paths = Set(roots.map { $0.standardizedFileURL.path })
        #expect(paths.contains(resourcesURL.standardizedFileURL.path))
        #expect(paths.contains(bundleURL.standardizedFileURL.path))
        #expect(paths.contains(bundleURL.appendingPathComponent("Resources", isDirectory: true).standardizedFileURL.path))
    }
}
