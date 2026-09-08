import Foundation

enum ResourceLocator {
    private static let riftResourceBundleName = "Rift_Rift.bundle"

    static func url(forResource name: String, withExtension ext: String, subdirectory: String? = nil) -> URL? {
        let fileName = "\(name).\(ext)"
        for root in resourceRoots() {
            let base = subdirectory.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
            let candidate = base.appendingPathComponent(fileName, isDirectory: false)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func resourceRoots() -> [URL] {
        var roots: [URL] = []
        let mainBundleURL = Bundle.main.bundleURL

        if let resourceURL = Bundle.main.resourceURL {
            appendResourceBundleRoots(under: resourceURL, to: &roots)
            roots.append(resourceURL)
        }

        appendResourceBundleRoots(under: mainBundleURL, to: &roots)

        let contentsURL = mainBundleURL.appendingPathComponent("Contents", isDirectory: true)
        appendResourceBundleRoots(under: contentsURL.appendingPathComponent("Resources", isDirectory: true), to: &roots)
        appendResourceBundleRoots(under: contentsURL.appendingPathComponent("MacOS", isDirectory: true), to: &roots)

        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            appendResourceBundleRoots(under: executableDirectory, to: &roots)
        }

        return uniqueExistingDirectories(roots)
    }

    private static func appendResourceBundleRoots(under parent: URL, to roots: inout [URL]) {
        roots.append(contentsOf: resourceBundleRoots(under: parent))
    }

    static func resourceBundleRoots(under parent: URL) -> [URL] {
        let bundleURL = parent.appendingPathComponent(riftResourceBundleName, isDirectory: true)
        var roots = [bundleURL]
        if let resourceURL = Bundle(url: bundleURL)?.resourceURL {
            roots.append(resourceURL)
            roots.append(resourceURL.appendingPathComponent("Resources", isDirectory: true))
        }
        roots.append(bundleURL.appendingPathComponent("Resources", isDirectory: true))
        return roots
    }

    private static func uniqueExistingDirectories(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return false
            }
            return seen.insert(url.standardizedFileURL.path).inserted
        }
    }
}
