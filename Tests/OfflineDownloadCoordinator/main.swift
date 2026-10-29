import Foundation

struct OfflineSavedTrack { let uri: String }
final class OfflineTrackStore {
    static let shared = OfflineTrackStore()
    var saves = 0
    var savedURIs = Set<String>()
    var failRead = false
    var readCount = 0
    var removeOnReadNumber: Int?
    var removeURI: String?
    func tracks() throws -> [OfflineSavedTrack] {
        guard !Thread.isMainThread else { fatalError("collection index read blocked main thread") }
        readCount += 1
        if failRead { throw TestError.failed }
        if removeOnReadNumber == readCount, let removeURI { savedURIs.remove(removeURI) }
        return savedURIs.map { OfflineSavedTrack(uri: $0) }
    }
    func save(uri: String, title: String, artist: String, stagedWAV: URL) throws -> OfflineSavedTrack {
        guard FileManager.default.fileExists(atPath: stagedWAV.path) else { fatalError("missing WAV") }
        saves += 1
        savedURIs.insert(uri)
        return OfflineSavedTrack(uri: uri)
    }
}
enum TestError: Error { case failed }

enum OfflineCollectionCatalog {
    struct Track { let uri: String; let title: String; let artist: String }
    enum Kind { case album, playlist }
    enum CatalogError: Error { case invalidResponse }
    struct Collection {
        let uri: String
        let kind: Kind
        let tracks: [Track]
        var trackURIs: [String] { tracks.map(\.uri) }
        var uniqueTracks: [Track] {
            var seen = Set<String>()
            return tracks.filter { seen.insert($0.uri).inserted }
        }
    }
    static let maxTracks = 5_000
    static var fetchResult: Result<Collection, CatalogError>?
    static var fetchCalls = 0
    static func kind(for uri: String) -> Kind? {
        if uri.hasPrefix("spotify:album:") { return .album }
        if uri.hasPrefix("spotify:playlist:") { return .playlist }
        return nil
    }
    static func fetch(uri: String, completion: @escaping (Result<Collection, CatalogError>) -> Void) {
        fetchCalls += 1
        guard let result = fetchResult else { fatalError("unexpected collection re-fetch") }
        DispatchQueue.main.async { completion(result) }
    }
}

enum SpotifyAudioAssetResolver {
    enum ResolverError: Error { case failed, playbackKeyUnavailable }
    struct EncryptedAsset {
        let trackURI: String
        let fileID: Data
        let encryptedFileURL: URL
        let encryptedByteCount: Int64
    }
    static var staged: URL?
    static var assetIDByte: UInt8 = 2
    static var downloadCalls = 0
    static var stagedCalls = 0
    static func isCanonicalTrackURI(_ uri: String) -> Bool {
        let prefix = "spotify:track:"
        return uri.hasPrefix(prefix) && uri.utf8.count == prefix.utf8.count + 22
    }
    static func download(trackURI: String, fileIDPreflight: @escaping (Data) -> Bool,
                         completion: @escaping (Result<EncryptedAsset, ResolverError>) -> Void) {
        downloadCalls += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            let fileID = Data(repeating: assetIDByte, count: 20)
            guard fileIDPreflight(fileID) else {
                completion(.failure(.playbackKeyUnavailable)); return
            }
            stagedCalls += 1
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try! Data(repeating: 1, count: 172).write(to: url)
            staged = url
            completion(.success(EncryptedAsset(trackURI: trackURI, fileID: fileID,
                                               encryptedFileURL: url, encryptedByteCount: 172)))
        }
    }
}

private let uri = "spotify:track:0123456789ABCDEFGHIJKL"
private let otherURI = "spotify:track:ABCDEFGHIJKL0123456789"
private var keyAvailable = true
private var consumeSucceeds = true
private var hookInstalled = true
private var keyGeneration: UInt64 = 1
private var keyConsumeCalls = 0
private var decryptOK = true
private var decodeOK = true
private var intermediate: [URL] = []

@_cdecl("ppkc_install")
func installKeyHook() -> Int32 { hookInstalled ? 1 : 0 }

@_cdecl("ppkc_generation")
func capturedGeneration() -> UInt64 { keyGeneration }

@_cdecl("ppkc_has_for_file_id")
func hasKey(_ fileID: UnsafePointer<UInt8>?) -> Int32 {
    guard keyAvailable, let fileID,
          (0..<20).allSatisfy({ fileID[$0] == 2 }) else { return 0 }
    return 1
}

@_cdecl("ppkc_consume_for_file_id")
func key(_ fileID: UnsafePointer<UInt8>?, _ record: UnsafeMutablePointer<UInt8>?,
         _ output: UnsafeMutablePointer<UInt64>?) -> Int32 {
    guard let staged = SpotifyAudioAssetResolver.staged,
          FileManager.default.fileExists(atPath: staged.path) else {
        fatalError("key consumed before asset resolution")
    }
    keyConsumeCalls += 1
    guard consumeSucceeds, let record, let fileID,
          (0..<20).allSatisfy({ fileID[$0] == 2 }) else { return 0 }
    for index in 0..<28 { record[index] = 9 }
    output?.pointee = 1
    return 1
}

@_cdecl("ppc_decrypt_file_to_ogg")
func decrypt(_ source: UnsafePointer<CChar>?, _ output: UnsafePointer<CChar>?,
             _ record: UnsafeRawPointer?, _ count: Int) -> Int32 {
    guard let source, let output, record != nil, count == 28 else { return -1 }
    guard FileManager.default.fileExists(atPath: String(cString: source)) else { fatalError("missing encrypted input") }
    let path = URL(fileURLWithPath: String(cString: output))
    intermediate.append(path)
    if !decryptOK { return -1 }
    try! Data("OggS".utf8).write(to: path)
    return 0
}

@_cdecl("ppc_decode_ogg_to_wav")
func decode(_ input: UnsafePointer<CChar>?, _ output: UnsafePointer<CChar>?) -> Int32 {
    guard let input, let output else { return -1 }
    guard FileManager.default.fileExists(atPath: String(cString: input)) else { fatalError("missing Ogg") }
    let path = URL(fileURLWithPath: String(cString: output))
    intermediate.append(path)
    if !decodeOK { return -1 }
    try! Data("RIFF".utf8).write(to: path)
    return 0
}

private func wait(_ count: Int) {
    let deadline = Date().addingTimeInterval(5)
    while results.count < count && Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    guard results.count == count else { fatalError("completion missing") }
}

private func waitBatch(_ count: Int) {
    let deadline = Date().addingTimeInterval(5)
    while batchResults.count < count && Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    guard batchResults.count == count else { fatalError("collection completion missing") }
}

var results: [Result<OfflineSavedTrack, OfflineDownloadError>] = []
hookInstalled = false
OfflineDownloadCoordinator.shared.download(trackURI: uri, title: "Title", artist: "Artist") { results.append($0) }
wait(1)
guard case .failure(.noPlaybackKey) = results[0], SpotifyAudioAssetResolver.downloadCalls == 0 else {
    fatalError("missing hook started network download")
}
results.removeAll(); hookInstalled = true; keyGeneration = 0
OfflineDownloadCoordinator.shared.download(trackURI: uri, title: "Title", artist: "Artist") { results.append($0) }
wait(1)
guard case .failure(.noPlaybackKey) = results[0], SpotifyAudioAssetResolver.downloadCalls == 0 else {
    fatalError("missing playback key started network download")
}
results.removeAll(); keyGeneration = 1
OfflineDownloadCoordinator.shared.download(trackURI: uri, title: "Title", artist: "Artist") { results.append($0) }
OfflineDownloadCoordinator.shared.download(trackURI: uri, title: "Title", artist: "Artist") { results.append($0) }
wait(2)
guard results.contains(where: { if case .success = $0 { return true }; return false }),
      results.contains(where: { if case .failure(.alreadyDownloading) = $0 { return true }; return false }) else {
    fatalError("success or duplicate guard missing")
}
guard OfflineTrackStore.shared.saves == 1 else { fatalError("save count") }

for (keyOK, consumeOK, decryptWorks, decodeWorks) in
    [(false, true, true, true), (true, false, true, true),
     (true, true, false, true), (true, true, true, false)] {
    keyAvailable = keyOK; consumeSucceeds = consumeOK
    decryptOK = decryptWorks; decodeOK = decodeWorks
    let oldStagedCalls = SpotifyAudioAssetResolver.stagedCalls
    results.removeAll(); intermediate.removeAll()
    OfflineDownloadCoordinator.shared.download(trackURI: uri, title: "Title", artist: "Artist") { results.append($0) }
    wait(1)
    guard case .failure = results[0], OfflineTrackStore.shared.saves == 1 else {
        fatalError("failed stage was indexed")
    }
    guard SpotifyAudioAssetResolver.stagedCalls == oldStagedCalls + (keyOK ? 1 : 0),
          SpotifyAudioAssetResolver.staged.map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true,
          intermediate.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else {
        fatalError("failed stage left a file")
    }
}
keyAvailable = true; consumeSucceeds = true
SpotifyAudioAssetResolver.assetIDByte = 3; decryptOK = true; decodeOK = true
let stagedBeforeWrongID = SpotifyAudioAssetResolver.stagedCalls
results.removeAll(); intermediate.removeAll()
OfflineDownloadCoordinator.shared.download(trackURI: uri, title: "Title", artist: "Artist") { results.append($0) }
wait(1)
guard case .failure(.noPlaybackKey) = results[0], OfflineTrackStore.shared.saves == 1,
      SpotifyAudioAssetResolver.stagedCalls == stagedBeforeWrongID else {
    fatalError("wrong file ID began CDN or was saved")
}

SpotifyAudioAssetResolver.assetIDByte = 2
var batchResults: [OfflineCollectionDownloadCompletion] = []
let albumURI = "spotify:album:0123456789ABCDEFGHIJKL"
let trackA = OfflineCollectionCatalog.Track(uri: uri, title: "A", artist: "Artist")
let trackB = OfflineCollectionCatalog.Track(uri: otherURI, title: "B", artist: "Artist")
let album = OfflineCollectionCatalog.Collection(uri: albumURI, kind: .album,
                                                tracks: [trackA, trackB, trackB])
OfflineDownloadCoordinator.shared.download(collection: album) { batchResults.append($0) }
waitBatch(1)
guard case .complete(let complete) = batchResults[0], complete.isComplete,
      complete.items.count == 2, complete.plannedCount == 2, !complete.cancelled,
      case .alreadySaved = complete.items[0].outcome,
      case .saved(let saved) = complete.items[1].outcome, saved.uri == otherURI,
      OfflineTrackStore.shared.saves == 2 else {
    fatalError("deduplicated collection success incorrect")
}

let missingURI = "spotify:track:1111111111111111111111"
let missing = OfflineCollectionCatalog.Track(uri: missingURI, title: "C", artist: "Artist")
let partialAlbum = OfflineCollectionCatalog.Collection(uri: albumURI, kind: .album,
                                                       tracks: [trackA, trackB, missing])
keyAvailable = false
let stagedBeforePartial = SpotifyAudioAssetResolver.stagedCalls
OfflineDownloadCoordinator.shared.download(collection: partialAlbum) { batchResults.append($0) }
waitBatch(2)
guard case .partial(let partial) = batchResults[1], !partial.isComplete,
      partial.items.count == 3, partial.plannedCount == 3, !partial.cancelled,
      case .alreadySaved = partial.items[0].outcome,
      case .alreadySaved = partial.items[1].outcome,
      case .failed(.noPlaybackKey) = partial.items[2].outcome,
      SpotifyAudioAssetResolver.stagedCalls == stagedBeforePartial,
      OfflineTrackStore.shared.saves == 2 else {
    fatalError("partial collection falsely completed or staged missing-key asset")
}

let concurrentURI = "spotify:track:2222222222222222222222"
let concurrentTrack = OfflineCollectionCatalog.Track(uri: concurrentURI, title: "D", artist: "Artist")
let oneMore = OfflineCollectionCatalog.Collection(uri: albumURI, kind: .album, tracks: [concurrentTrack])
keyAvailable = true
results.removeAll()
OfflineDownloadCoordinator.shared.download(collection: oneMore) { batchResults.append($0) }
OfflineDownloadCoordinator.shared.download(trackURI: uri, title: "A", artist: "Artist") { results.append($0) }
wait(1); waitBatch(3)
guard case .failure(.alreadyDownloading) = results[0],
      case .complete(let concurrent) = batchResults[2], concurrent.isComplete else {
    fatalError("single-track operation ran during collection")
}

OfflineTrackStore.shared.removeURI = uri
OfflineTrackStore.shared.removeOnReadNumber = OfflineTrackStore.shared.readCount + 2
let oneSaved = OfflineCollectionCatalog.Collection(uri: albumURI, kind: .album, tracks: [trackA])
OfflineDownloadCoordinator.shared.download(collection: oneSaved) { batchResults.append($0) }
waitBatch(4)
guard case .partial(let disappeared) = batchResults[3], !disappeared.isComplete,
      case .failed(.savedFileMissing) = disappeared.items[0].outcome else {
    fatalError("deleted saved item falsely completed")
}

OfflineTrackStore.shared.failRead = true
OfflineDownloadCoordinator.shared.download(collection: album) { batchResults.append($0) }
waitBatch(5)
guard case .failedToStart(.indexFailed) = batchResults[4] else {
    fatalError("invalid saved index did not stop collection")
}

OfflineTrackStore.shared.failRead = false
OfflineTrackStore.shared.removeOnReadNumber = nil
OfflineTrackStore.shared.removeURI = nil
let newA = OfflineCollectionCatalog.Track(uri: "spotify:track:3333333333333333333333", title: "E", artist: "Artist")
let newB = OfflineCollectionCatalog.Track(uri: "spotify:track:4444444444444444444444", title: "F", artist: "Artist")
let newC = OfflineCollectionCatalog.Track(uri: "spotify:track:5555555555555555555555", title: "G", artist: "Artist")
let newAlbum = OfflineCollectionCatalog.Collection(uri: albumURI, kind: .album,
                                                   tracks: [newA, newB, newC, newB])

let callsBeforeImmediateCancel = SpotifyAudioAssetResolver.downloadCalls
let immediateID = OfflineDownloadCoordinator.shared.download(collection: newAlbum) {
    batchResults.append($0)
}
OfflineDownloadCoordinator.shared.cancelCollection(id: immediateID)
waitBatch(6)
guard case .partial(let immediate) = batchResults[5], !immediate.isComplete,
      immediate.cancelled, immediate.stopReason == .userCancelled,
      immediate.plannedCount == 3, immediate.items.isEmpty,
      SpotifyAudioAssetResolver.downloadCalls == callsBeforeImmediateCancel else {
    fatalError("same-turn cancellation was lost before queued start")
}

let callsBeforeEarlyCancel = SpotifyAudioAssetResolver.downloadCalls
var earlyID: UUID?
var earlyProgress: [Int] = []
earlyID = OfflineDownloadCoordinator.shared.download(collection: newAlbum, progress: { update in
    earlyProgress.append(update.processedCount)
    if update.processedCount == 0, let earlyID {
        OfflineDownloadCoordinator.shared.cancelCollection(id: earlyID)
    }
}) { batchResults.append($0) }
waitBatch(7)
guard case .partial(let early) = batchResults[6], !early.isComplete,
      early.cancelled, early.plannedCount == 3, early.items.isEmpty,
      earlyProgress == [0],
      SpotifyAudioAssetResolver.downloadCalls == callsBeforeEarlyCancel else {
    fatalError("early cancellation started asset transfer or falsely completed")
}

let callsBeforeStaleID = SpotifyAudioAssetResolver.downloadCalls
var staleProgress: [Int] = []
OfflineDownloadCoordinator.shared.download(collection: newAlbum, progress: { update in
    guard update.plannedCount == 3 else { fatalError("wrong progress denominator") }
    staleProgress.append(update.processedCount)
    if update.processedCount == 0 {
        OfflineDownloadCoordinator.shared.cancelCollection(id: UUID())
    }
}) { batchResults.append($0) }
waitBatch(8)
guard case .complete(let afterStaleID) = batchResults[7], afterStaleID.isComplete,
      afterStaleID.plannedCount == 3, !afterStaleID.cancelled,
      staleProgress == [0, 1, 2, 3],
      SpotifyAudioAssetResolver.downloadCalls == callsBeforeStaleID + 3 else {
    fatalError("stale ID cancelled active job or progress was incorrect")
}

let cancelA = OfflineCollectionCatalog.Track(uri: "spotify:track:6666666666666666666666", title: "H", artist: "Artist")
let cancelB = OfflineCollectionCatalog.Track(uri: "spotify:track:7777777777777777777777", title: "I", artist: "Artist")
let cancelAlbum = OfflineCollectionCatalog.Collection(uri: albumURI, kind: .album,
                                                      tracks: [cancelA, cancelB, cancelB])
let callsBeforeCancel = SpotifyAudioAssetResolver.downloadCalls
var cancelProgress: [Int] = []
var cancelID: UUID?
cancelID = OfflineDownloadCoordinator.shared.download(collection: cancelAlbum, progress: { update in
    cancelProgress.append(update.processedCount)
    if update.processedCount == 1, let cancelID {
        OfflineDownloadCoordinator.shared.cancelCollection(id: cancelID)
    }
}) { batchResults.append($0) }
waitBatch(9)
guard case .partial(let cancelled) = batchResults[8], !cancelled.isComplete,
      cancelled.cancelled, cancelled.plannedCount == 2, cancelled.items.count == 1,
      case .saved(let firstSaved) = cancelled.items[0].outcome, firstSaved.uri == cancelA.uri,
      cancelProgress == [0, 1],
      SpotifyAudioAssetResolver.downloadCalls == callsBeforeCancel + 1 else {
    fatalError("cancelled job started another track or falsely completed")
}
_ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
guard batchResults.count == 9 else { fatalError("cancelled job completed more than once") }

let callsBeforeExpired = SpotifyAudioAssetResolver.downloadCalls
OfflineDownloadCoordinator.shared.download(collection: cancelAlbum, deadline: .distantPast) {
    batchResults.append($0)
}
waitBatch(10)
guard case .failedToStart(.deadlineExceeded) = batchResults[9],
      SpotifyAudioAssetResolver.downloadCalls == callsBeforeExpired else {
    fatalError("expired job began a track")
}

OfflineTrackStore.shared.savedURIs.remove(cancelA.uri)
let deadline = Date().addingTimeInterval(2)
let callsBeforeDeadline = SpotifyAudioAssetResolver.downloadCalls
var deadlineProgress: [Int] = []
OfflineDownloadCoordinator.shared.download(collection: cancelAlbum, deadline: deadline, progress: { update in
    deadlineProgress.append(update.processedCount)
    if update.processedCount == 1 { Thread.sleep(until: deadline.addingTimeInterval(0.05)) }
}) { batchResults.append($0) }
waitBatch(11)
guard case .partial(let expired) = batchResults[10], !expired.isComplete,
      !expired.cancelled, expired.stopReason == .deadlineExceeded,
      expired.plannedCount == 2, expired.items.count == 1,
      case .saved(let savedBeforeDeadline) = expired.items[0].outcome,
      savedBeforeDeadline.uri == cancelA.uri,
      deadlineProgress == [0, 1],
      SpotifyAudioAssetResolver.downloadCalls == callsBeforeDeadline + 1 else {
    fatalError("deadline did not stop before next track")
}

let callsBeforeResume = SpotifyAudioAssetResolver.downloadCalls
OfflineDownloadCoordinator.shared.download(collection: cancelAlbum) { batchResults.append($0) }
waitBatch(12)
guard case .complete(let resumed) = batchResults[11], resumed.isComplete,
      resumed.plannedCount == 2, !resumed.cancelled,
      SpotifyAudioAssetResolver.downloadCalls == callsBeforeResume + 1 else {
    fatalError("cancelled job blocked a subsequent complete job")
}

let playlistURI = "spotify:playlist:0123456789ABCDEFGHIJKL"
let playlistA = OfflineCollectionCatalog.Track(uri: "spotify:track:8888888888888888888888",
                                               title: "P1", artist: "Artist")
let playlistB = OfflineCollectionCatalog.Track(uri: "spotify:track:9999999999999999999999",
                                               title: "P2", artist: "Artist")
let playlistC = OfflineCollectionCatalog.Track(uri: "spotify:track:AAAAAAAAAAAAAAAAAAAAAA",
                                               title: "P3", artist: "Artist")
let playlist = OfflineCollectionCatalog.Collection(uri: playlistURI, kind: .playlist,
                                                    tracks: [playlistA, playlistB, playlistA])
OfflineCollectionCatalog.fetchResult = .success(playlist)
OfflineDownloadCoordinator.shared.download(collection: playlist) { batchResults.append($0) }
waitBatch(13)
guard case .complete(let verifiedPlaylist) = batchResults[12], verifiedPlaylist.isComplete,
      verifiedPlaylist.collectionCheck == .matched, verifiedPlaylist.plannedCount == 2,
      OfflineCollectionCatalog.fetchCalls == 1 else {
    fatalError("matching playlist snapshot did not complete")
}

OfflineCollectionCatalog.fetchResult = .success(.init(uri: playlistURI, kind: .playlist,
                                                       tracks: [playlistA, playlistC, playlistA]))
OfflineDownloadCoordinator.shared.download(collection: playlist) { batchResults.append($0) }
waitBatch(14)
guard case .partial(let changedPlaylist) = batchResults[13], !changedPlaylist.isComplete,
      changedPlaylist.collectionCheck == .changed, changedPlaylist.items.count == 2,
      changedPlaylist.items.allSatisfy({ if case .alreadySaved = $0.outcome { return true }; return false }),
      OfflineCollectionCatalog.fetchCalls == 2 else {
    fatalError("same-count playlist edit was shown as complete")
}

OfflineCollectionCatalog.fetchResult = .failure(.invalidResponse)
OfflineDownloadCoordinator.shared.download(collection: playlist) { batchResults.append($0) }
waitBatch(15)
guard case .partial(let unverifiedPlaylist) = batchResults[14], !unverifiedPlaylist.isComplete,
      unverifiedPlaylist.collectionCheck == .unavailable,
      OfflineCollectionCatalog.fetchCalls == 3 else {
    fatalError("playlist re-fetch failure was shown as complete")
}

keyAvailable = false
let partialPlaylist = OfflineCollectionCatalog.Collection(uri: playlistURI, kind: .playlist,
                                                           tracks: [playlistA, playlistC])
OfflineDownloadCoordinator.shared.download(collection: partialPlaylist) { batchResults.append($0) }
waitBatch(16)
guard case .partial(let failedPlaylist) = batchResults[15], !failedPlaylist.isComplete,
      failedPlaylist.collectionCheck == .notChecked,
      OfflineCollectionCatalog.fetchCalls == 3 else {
    fatalError("failed playlist unnecessarily re-fetched or falsely completed")
}

keyAvailable = true
let finalTrack = OfflineCollectionCatalog.Track(uri: "spotify:track:BBBBBBBBBBBBBBBBBBBBBB",
                                                title: "Last", artist: "Artist")
let finalTrackAlbum = OfflineCollectionCatalog.Collection(uri: albumURI, kind: .album,
                                                           tracks: [finalTrack])
let finalDeadline = Date().addingTimeInterval(2)
OfflineDownloadCoordinator.shared.download(collection: finalTrackAlbum, deadline: finalDeadline,
                                           progress: { update in
    if update.processedCount == 1 { Thread.sleep(until: finalDeadline.addingTimeInterval(0.05)) }
}) { batchResults.append($0) }
waitBatch(17)
guard case .partial(let finalExpired) = batchResults[16], !finalExpired.isComplete,
      finalExpired.stopReason == .deadlineExceeded, finalExpired.plannedCount == 1,
      finalExpired.items.count == 1,
      case .saved(let finalSaved) = finalExpired.items[0].outcome,
      finalSaved.uri == finalTrack.uri else {
    fatalError("final track exceeded deadline but collection was shown as complete")
}
print("OfflineDownloadCoordinator tests passed")
