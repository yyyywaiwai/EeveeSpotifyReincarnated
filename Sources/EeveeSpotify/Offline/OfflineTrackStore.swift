import Foundation

struct OfflineSavedTrack: Codable, Equatable {
    let uri: String
    let title: String
    let artist: String
    let fileID: UUID
    let byteCount: UInt64
}

enum OfflineTrackStoreError: Error {
    case invalidTrackURI
    case invalidWAV
    case invalidIndex
}

final class OfflineTrackStore {
    static let shared = OfflineTrackStore(directory: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    )[0].appendingPathComponent("EeveeSpotify/Offline", isDirectory: true))
    static let changedNotification = Notification.Name("EeveeOfflineTrackStoreChanged")

    private let directory: URL
    private let manager: FileManager
    private let lock = NSLock()
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    init(directory: URL, manager: FileManager = .default) {
        self.directory = directory
        self.manager = manager
    }

    // The caller owns stagedWAV and may remove it after a successful import.
    func save(uri: String, title: String, artist: String, stagedWAV: URL) throws -> OfflineSavedTrack {
        guard Self.validTrackURI(uri) else { throw OfflineTrackStoreError.invalidTrackURI }
        let sourceBytes = try validatedWAVBytes(stagedWAV)
        lock.lock(); defer { lock.unlock() }
        var index = try readIndex()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try excludeFromBackup()
        let entry = OfflineSavedTrack(uri: uri, title: title, artist: artist,
                                      fileID: UUID(), byteCount: sourceBytes)
        let destination = fileURL(for: entry)
        do {
            try manager.copyItem(at: stagedWAV, to: destination)
            guard try validatedWAVBytes(destination) == sourceBytes else {
                throw OfflineTrackStoreError.invalidWAV
            }
            let old = index.updateValue(entry, forKey: uri)
            try writeIndex(index)
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changedNotification, object: nil) }
            if let old { try? manager.removeItem(at: fileURL(for: old)) }
            return entry
        } catch {
            try? manager.removeItem(at: destination)
            throw error
        }
    }

    func tracks() throws -> [OfflineSavedTrack] {
        lock.lock(); defer { lock.unlock() }
        return try readIndex().values.filter { entry in
            (try? validatedWAVBytes(fileURL(for: entry))) == entry.byteCount
        }.sorted { $0.uri < $1.uri }
    }

    func fileURL(for uri: String) throws -> URL? {
        guard Self.validTrackURI(uri) else { throw OfflineTrackStoreError.invalidTrackURI }
        lock.lock(); defer { lock.unlock() }
        guard let entry = try readIndex()[uri],
              (try? validatedWAVBytes(fileURL(for: entry))) == entry.byteCount else { return nil }
        return fileURL(for: entry)
    }

    func remove(uri: String) throws {
        guard Self.validTrackURI(uri) else { throw OfflineTrackStoreError.invalidTrackURI }
        lock.lock(); defer { lock.unlock() }
        var index = try readIndex()
        guard let entry = index.removeValue(forKey: uri) else { return }
        let path = fileURL(for: entry)
        let pending = path.appendingPathExtension("deleting")
        let hasFile = manager.fileExists(atPath: path.path)
        if hasFile { try manager.moveItem(at: path, to: pending) }
        do {
            try writeIndex(index)
        } catch {
            if hasFile { try manager.moveItem(at: pending, to: path) }
            throw error
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changedNotification, object: nil) }
        // shortcut: a failed post-commit unlink can orphan a tombstone; add cleanup if observed in production.
        if hasFile { try? manager.removeItem(at: pending) }
    }

    private func fileURL(for entry: OfflineSavedTrack) -> URL {
        directory.appendingPathComponent(entry.fileID.uuidString).appendingPathExtension("wav")
    }

    private func readIndex() throws -> [String: OfflineSavedTrack] {
        if manager.fileExists(atPath: directory.path) { try excludeFromBackup() }
        guard manager.fileExists(atPath: indexURL.path) else { return [:] }
        let index = try JSONDecoder().decode([String: OfflineSavedTrack].self,
                                             from: Data(contentsOf: indexURL))
        guard index.allSatisfy({ $0.key == $0.value.uri && Self.validTrackURI($0.key) }) else {
            throw OfflineTrackStoreError.invalidIndex
        }
        // Restore a deletion interrupted before its index commit.
        for entry in index.values {
            let path = fileURL(for: entry)
            let pending = path.appendingPathExtension("deleting")
            if !manager.fileExists(atPath: path.path), manager.fileExists(atPath: pending.path) {
                try manager.moveItem(at: pending, to: path)
            }
        }
        return index
    }

    private func writeIndex(_ index: [String: OfflineSavedTrack]) throws {
        try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
    }

    private func excludeFromBackup() throws {
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }

    private static func validTrackURI(_ uri: String) -> Bool {
        let prefix = "spotify:track:"
        guard uri.hasPrefix(prefix) else { return false }
        let id = uri.dropFirst(prefix.count).utf8
        return id.count == 22 && id.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }

    private func validatedWAVBytes(_ url: URL) throws -> UInt64 {
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              size >= 48, size <= UInt64(UInt32.max) + 8 else {
            throw OfflineTrackStoreError.invalidWAV
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        let header = handle.readData(ofLength: 44)
        guard header.count == 44 else { throw OfflineTrackStoreError.invalidWAV }
        func u16(_ offset: Int) -> UInt16 {
            UInt16(header[offset]) | UInt16(header[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(header[offset]) | UInt32(header[offset + 1]) << 8 |
                UInt32(header[offset + 2]) << 16 | UInt32(header[offset + 3]) << 24
        }
        let channels = u16(22), rate = u32(24), dataBytes = u32(40)
        guard header.prefix(4).elementsEqual("RIFF".utf8),
              header[8..<16].elementsEqual("WAVEfmt ".utf8),
              header[36..<40].elementsEqual("data".utf8),
              u32(4) == size - 8, u32(16) == 16, u16(20) == 1,
              (1...2).contains(channels), (8_000...192_000).contains(rate),
              u16(34) == 16, u16(32) == channels * 2,
              u32(28) == rate * UInt32(channels) * 2,
              dataBytes > 0, UInt64(dataBytes) == size - 44,
              dataBytes % UInt32(channels * 2) == 0 else {
            throw OfflineTrackStoreError.invalidWAV
        }
        return size
    }
}
