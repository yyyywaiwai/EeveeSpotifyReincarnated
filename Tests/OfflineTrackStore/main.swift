import Foundation

private func require(_ condition: Bool, _ message: String) {
    guard condition else { fatalError(message) }
}

private let trackURI = "spotify:track:0123456789ABCDEFGHIJKL"
private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }

private func wav(_ payload: Data) -> Data {
    var data = Data()
    func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
    func u16(_ value: UInt16) { data.append(contentsOf: [UInt8(value & 255), UInt8(value >> 8)]) }
    func u32(_ value: UInt32) {
        data.append(contentsOf: [UInt8(value & 255), UInt8((value >> 8) & 255),
                                 UInt8((value >> 16) & 255), UInt8(value >> 24)])
    }
    ascii("RIFF"); u32(UInt32(payload.count + 36)); ascii("WAVEfmt "); u32(16)
    u16(1); u16(2); u32(44_100); u32(176_400); u16(4); u16(16)
    ascii("data"); u32(UInt32(payload.count)); data.append(payload)
    return data
}

private func stage(_ name: String, bytes: Data) throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent(name)
    try bytes.write(to: url)
    return url
}

let store = OfflineTrackStore(directory: root.appendingPathComponent("library"))
let badURI = "spotify:track:../../escape"
let initial = try stage("initial.wav", bytes: wav(Data([1, 2, 3, 4, 5, 6, 7, 8])))
do {
    _ = try store.save(uri: badURI, title: "bad", artist: "bad", stagedWAV: initial)
    fatalError("invalid URI accepted")
} catch OfflineTrackStoreError.invalidTrackURI {}
require(FileManager.default.fileExists(atPath: initial.path), "invalid URI deleted source")

let corrupt = try stage("corrupt.wav", bytes: Data(repeating: 0, count: 48))
do {
    _ = try store.save(uri: trackURI, title: "bad", artist: "bad", stagedWAV: corrupt)
    fatalError("corrupt WAV accepted")
} catch OfflineTrackStoreError.invalidWAV {}
require(try store.tracks().isEmpty, "corrupt WAV indexed")

let savedSignal = DispatchSemaphore(value: 0)
let savedObserver = NotificationCenter.default.addObserver(
    forName: OfflineTrackStore.changedNotification, object: nil, queue: nil
) { _ in savedSignal.signal() }
let first = try store.save(uri: trackURI, title: "First", artist: "Artist", stagedWAV: initial)
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
require(savedSignal.wait(timeout: .now()) == .success, "committed save did not notify observers")
NotificationCenter.default.removeObserver(savedObserver)
require(try root.appendingPathComponent("library").resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
        "download directory not excluded from backup")
let firstURL = try store.fileURL(for: trackURI)
require(firstURL != nil && FileManager.default.fileExists(atPath: firstURL!.path), "WAV not saved")
require(first.byteCount == UInt64(wav(Data(repeating: 0, count: 8)).count), "wrong byte count")
require(try store.tracks() == [first], "track not listed")
require(FileManager.default.fileExists(atPath: initial.path), "save consumed caller's staged file")

let replacement = try stage("replacement.wav", bytes: wav(Data(repeating: 9, count: 16)))
let second = try store.save(uri: trackURI, title: "Second", artist: "Artist", stagedWAV: replacement)
require(second.fileID != first.fileID, "replacement reused path")
require(try store.tracks() == [second], "replacement not committed")
require(!FileManager.default.fileExists(atPath: firstURL!.path), "old WAV not cleaned")

let secondURL = try store.fileURL(for: trackURI)!
let interrupted = secondURL.appendingPathExtension("deleting")
try FileManager.default.moveItem(at: secondURL, to: interrupted)
require(try store.tracks() == [second], "interrupted deletion lost the indexed track")
require(FileManager.default.fileExists(atPath: secondURL.path) &&
        !FileManager.default.fileExists(atPath: interrupted.path), "interrupted deletion not restored")
try Data(repeating: 0, count: 48).write(to: secondURL)
require(try store.tracks().isEmpty, "corrupt saved WAV shown as downloaded")
require(try store.fileURL(for: trackURI) == nil, "corrupt saved WAV exposed for playback")
RunLoop.main.run(until: Date().addingTimeInterval(0.1)) // Drain the replacement-save notification.
let removedSignal = DispatchSemaphore(value: 0)
let removedObserver = NotificationCenter.default.addObserver(
    forName: OfflineTrackStore.changedNotification, object: nil, queue: nil
) { _ in removedSignal.signal() }
try store.remove(uri: trackURI)
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
require(removedSignal.wait(timeout: .now()) == .success, "committed removal did not notify observers")
NotificationCenter.default.removeObserver(removedObserver)
require(try store.tracks().isEmpty && !FileManager.default.fileExists(atPath: secondURL.path),
        "remove left visible file")

let indexURL = root.appendingPathComponent("library/index.json")
try Data("{".utf8).write(to: indexURL)
do {
    _ = try store.save(uri: trackURI, title: "Third", artist: "Artist", stagedWAV: initial)
    fatalError("corrupt index overwritten")
} catch {}
require(try Data(contentsOf: indexURL) == Data("{".utf8), "corrupt index overwritten")
require(FileManager.default.fileExists(atPath: initial.path), "failed save deleted source")

private final class RefuseMoveManager: FileManager {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw NSError(domain: "OfflineTrackStoreTests", code: 2)
    }
}
let protectedDirectory = root.appendingPathComponent("protected-library")
let protectedStore = OfflineTrackStore(directory: protectedDirectory, manager: RefuseMoveManager())
let protected = try protectedStore.save(uri: trackURI, title: "Protected", artist: "Artist", stagedWAV: initial)
let protectedURL = try protectedStore.fileURL(for: trackURI)!
do {
    try protectedStore.remove(uri: trackURI)
    fatalError("failed file staging accepted as deletion")
} catch {}
require(try protectedStore.tracks() == [protected] &&
        FileManager.default.fileExists(atPath: protectedURL.path),
        "failed file staging removed the index or file")

private final class PartialCopyManager: FileManager {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try Data([1, 2, 3]).write(to: dstURL)
        throw NSError(domain: "OfflineTrackStoreTests", code: 1)
    }
}
let failedDirectory = root.appendingPathComponent("failed-library")
let failingStore = OfflineTrackStore(directory: failedDirectory, manager: PartialCopyManager())
do {
    _ = try failingStore.save(uri: trackURI, title: "Fail", artist: "Artist", stagedWAV: initial)
    fatalError("partial copy accepted")
} catch {}
require(try FileManager.default.contentsOfDirectory(atPath: failedDirectory.path).isEmpty,
        "failed copy left a partial WAV")
require(FileManager.default.fileExists(atPath: initial.path), "failed copy deleted source")

print("OfflineTrackStore tests passed")
