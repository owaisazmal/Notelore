import Foundation

/// Where recordings live: Application Support/Recordings. Sessions store
/// only the file name, so the container can move between launches.
enum AudioStorage {
    static func directory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func newFileName() -> String {
        UUID().uuidString + ".m4a"
    }

    static func url(forFileName name: String) -> URL? {
        guard !name.isEmpty, let dir = try? directory() else { return nil }
        return dir.appendingPathComponent(name)
    }

    static func delete(fileName: String?) {
        guard let fileName, let url = url(forFileName: fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func deleteAll() {
        guard let dir = try? directory() else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
