import EeveeSpotifyC
import Foundation

enum OfflineDownloadError: Error {
    case invalidTrackURI
    case invalidCollection
    case alreadyDownloading
    case deadlineExceeded
    case noPlaybackKey
    case indexFailed(Error)
    case savedFileMissing
    case invalidAsset
    case asset(SpotifyAudioAssetResolver.ResolverError)
    case decryptFailed
    case decodeFailed
    case saveFailed(Error)
}

struct OfflineCollectionDownloadResult {
    enum StopReason: Equatable {
        case userCancelled
        case deadlineExceeded
    }

    enum Outcome {
        case saved(OfflineSavedTrack)
        case alreadySaved
        case failed(OfflineDownloadError)
    }

    enum CollectionCheck {
        case notRequired
        case matched
        case changed
        case unavailable
        case notChecked
    }

    struct Item {
        let track: OfflineCollectionCatalog.Track
        var outcome: Outcome
    }

    let items: [Item]
    let plannedCount: Int
    let stopReason: StopReason?
    let collectionCheck: CollectionCheck

    var cancelled: Bool {
        if case .userCancelled = stopReason { return true }
        return false
    }

    var isComplete: Bool {
        stopReason == nil && (collectionCheck == .notRequired || collectionCheck == .matched) &&
            plannedCount > 0 && items.count == plannedCount && items.allSatisfy {
            if case .failed = $0.outcome { return false }
            return true
        }
    }
}

struct OfflineCollectionDownloadProgress {
    let processedCount: Int
    let plannedCount: Int
}

enum OfflineCollectionDownloadCompletion {
    case complete(OfflineCollectionDownloadResult)
    case partial(OfflineCollectionDownloadResult)
    case failedToStart(OfflineDownloadError)
}

/// Saves tracks only when a matching PlayPlay key has been captured.
final class OfflineDownloadCoordinator {
    static let shared = OfflineDownloadCoordinator()

    private let queue = DispatchQueue(label: "com.eeveespotify.offline-download", qos: .utility)
    private var isDownloading = false // Accessed only on the main queue.
    private var isBatchDownloading = false // Accessed only on the main queue.
    private var activeCollectionID: UUID? // Accessed only on the main queue.
    private var cancelCollectionRequested = false // Accessed only on the main queue.

    private init() {}

    /// Completion runs on the main queue. A wrong or stale playback key never creates a saved entry.
    func download(trackURI: String, title: String, artist: String,
                  completion: @escaping (Result<OfflineSavedTrack, OfflineDownloadError>) -> Void) {
        DispatchQueue.main.async {
            guard !self.isBatchDownloading else {
                completion(.failure(.alreadyDownloading)); return
            }
            self.downloadOne(trackURI: trackURI, title: title, artist: artist, completion: completion)
        }
    }

    /// A complete collection snapshot is processed serially; each distinct URI has its own outcome.
    /// Cancellation and the absolute deadline stop before the next track, preserving the current track's cleanup.
    // shortcut: an active track can run through its URLSession timeout and decoder before stopping; add resolver/codec cancellation if UI needs immediate stop.
    @discardableResult
    func download(collection: OfflineCollectionCatalog.Collection,
                  deadline: Date = Date().addingTimeInterval(24 * 60 * 60),
                  progress: ((OfflineCollectionDownloadProgress) -> Void)? = nil,
                  completion: @escaping (OfflineCollectionDownloadCompletion) -> Void) -> UUID {
        let id = UUID()
        DispatchQueue.main.async {
            let tracks = collection.uniqueTracks
            guard OfflineCollectionCatalog.kind(for: collection.uri) == collection.kind,
                  !tracks.isEmpty, tracks.count <= OfflineCollectionCatalog.maxTracks,
                  tracks.allSatisfy({ SpotifyAudioAssetResolver.isCanonicalTrackURI($0.uri) &&
                      !$0.title.isEmpty && !$0.artist.isEmpty }) else {
                completion(.failedToStart(.invalidCollection)); return
            }
            guard !self.isDownloading, !self.isBatchDownloading else {
                completion(.failedToStart(.alreadyDownloading)); return
            }
            guard deadline > Date() else {
                completion(.failedToStart(.deadlineExceeded)); return
            }
            self.isBatchDownloading = true
            self.activeCollectionID = id
            self.cancelCollectionRequested = false
            self.queue.async {
                do {
                    let savedURIs = Set(try OfflineTrackStore.shared.tracks().map(\.uri))
                    DispatchQueue.main.async {
                        self.downloadCollectionTracks(collection, id: id, deadline: deadline,
                                                      savedURIs: savedURIs, progress: progress,
                                                      completion: completion)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isBatchDownloading = false
                        self.activeCollectionID = nil
                        self.cancelCollectionRequested = false
                        completion(.failedToStart(.indexFailed(error)))
                    }
                }
            }
        }
        return id
    }

    func cancelCollection(id: UUID) {
        if Thread.isMainThread, activeCollectionID == id {
            cancelCollectionRequested = true
        } else {
            // A caller may cancel in the same turn as download(); its queued start runs first.
            DispatchQueue.main.async {
                guard self.activeCollectionID == id else { return }
                self.cancelCollectionRequested = true
            }
        }
    }

    private func downloadCollectionTracks(_ collection: OfflineCollectionCatalog.Collection,
                                          id: UUID, deadline: Date,
                                          savedURIs: Set<String>,
                                          progress: ((OfflineCollectionDownloadProgress) -> Void)?,
                                          completion: @escaping (OfflineCollectionDownloadCompletion) -> Void) {
        let tracks = collection.uniqueTracks
        var items: [OfflineCollectionDownloadResult.Item] = []
        items.reserveCapacity(tracks.count)
        progress?(.init(processedCount: 0, plannedCount: tracks.count))

        func finish(stopReason: OfflineCollectionDownloadResult.StopReason?) {
            func finishWithCheck(_ check: OfflineCollectionDownloadResult.CollectionCheck) {
                self.queue.async {
                    let verified: Result<Set<String>, Error> = Result {
                        Set(try OfflineTrackStore.shared.tracks().map(\.uri))
                    }
                    DispatchQueue.main.async {
                        for index in items.indices {
                            if case .failed = items[index].outcome { continue }
                            switch verified {
                            case .success(let uris) where uris.contains(items[index].track.uri): break
                            case .success: items[index].outcome = .failed(.savedFileMissing)
                            case .failure(let error): items[index].outcome = .failed(.indexFailed(error))
                            }
                        }
                        self.isBatchDownloading = false
                        self.activeCollectionID = nil
                        self.cancelCollectionRequested = false
                        let finalStopReason = stopReason ??
                            (Date() >= deadline ? .deadlineExceeded : nil)
                        let result = OfflineCollectionDownloadResult(items: items,
                                                                     plannedCount: tracks.count,
                                                                     stopReason: finalStopReason,
                                                                     collectionCheck: check)
                        completion(result.isComplete ? .complete(result) : .partial(result))
                    }
                }
            }
            guard collection.kind == .playlist else { finishWithCheck(.notRequired); return }
            guard stopReason == nil, items.count == tracks.count,
                  items.allSatisfy({ if case .failed = $0.outcome { return false }; return true }) else {
                finishWithCheck(.notChecked)
                return
            }
            // shortcut: a re-fetch can race concurrent edits; use a server revision when available.
            OfflineCollectionCatalog.fetch(uri: collection.uri) { latest in
                switch latest {
                case .success(let current):
                    finishWithCheck(current.kind == .playlist && current.uri == collection.uri &&
                        current.trackURIs == collection.trackURIs ? .matched : .changed)
                case .failure:
                    finishWithCheck(.unavailable)
                }
            }
        }

        func next(_ index: Int) {
            guard index < tracks.count else { finish(stopReason: nil); return }
            guard self.activeCollectionID == id, !self.cancelCollectionRequested else {
                finish(stopReason: .userCancelled)
                return
            }
            guard Date() < deadline else {
                finish(stopReason: .deadlineExceeded)
                return
            }
            let track = tracks[index]
            if savedURIs.contains(track.uri) {
                items.append(.init(track: track, outcome: .alreadySaved))
                progress?(.init(processedCount: items.count, plannedCount: tracks.count))
                DispatchQueue.main.async { next(index + 1) }
                return
            }
            downloadOne(trackURI: track.uri, title: track.title, artist: track.artist) { result in
                let outcome: OfflineCollectionDownloadResult.Outcome
                switch result {
                case .success(let saved) where saved.uri == track.uri:
                    outcome = .saved(saved)
                case .success:
                    outcome = .failed(.invalidAsset)
                case .failure(let error):
                    outcome = .failed(error)
                }
                items.append(.init(track: track, outcome: outcome))
                progress?(.init(processedCount: items.count, plannedCount: tracks.count))
                DispatchQueue.main.async { next(index + 1) }
            }
        }
        next(0)
    }

    private func downloadOne(trackURI: String, title: String, artist: String,
                             completion: @escaping (Result<OfflineSavedTrack, OfflineDownloadError>) -> Void) {
        guard SpotifyAudioAssetResolver.isCanonicalTrackURI(trackURI) else {
            completion(.failure(.invalidTrackURI)); return
        }
        guard !isDownloading else {
            completion(.failure(.alreadyDownloading)); return
        }
        guard ppkc_install() != 0, ppkc_generation() > 0 else {
            completion(.failure(.noPlaybackKey)); return
        }
        isDownloading = true

        SpotifyAudioAssetResolver.download(trackURI: trackURI, fileIDPreflight: { fileID in
            guard fileID.count == 20 else { return false }
            return fileID.withUnsafeBytes {
                ppkc_has_for_file_id($0.baseAddress?.assumingMemoryBound(to: UInt8.self)) != 0
            }
        }) { result in
                switch result {
                case .failure(let error):
                    if case .playbackKeyUnavailable = error {
                        self.finish(.failure(.noPlaybackKey), completion: completion)
                    } else {
                        self.finish(.failure(.asset(error)), completion: completion)
                    }
                case .success(let asset):
                    guard asset.trackURI == trackURI, asset.fileID.count == 20,
                          asset.encryptedByteCount >= 171 else {
                        try? FileManager.default.removeItem(at: asset.encryptedFileURL)
                        self.finish(.failure(.invalidAsset), completion: completion)
                        return
                    }
                    var keyRecord = [UInt8](repeating: 0, count: 28)
                    let captured = asset.fileID.withUnsafeBytes { fileID in
                        keyRecord.withUnsafeMutableBufferPointer { record in
                            ppkc_consume_for_file_id(
                                fileID.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                record.baseAddress, nil
                            )
                        }
                    }
                    guard captured != 0 else {
                        try? FileManager.default.removeItem(at: asset.encryptedFileURL)
                        self.finish(.failure(.noPlaybackKey), completion: completion)
                        return
                    }
                    self.queue.async {
                        let saved = self.process(asset, keyRecord: &keyRecord,
                                                 title: title, artist: artist)
                        DispatchQueue.main.async { self.finish(saved, completion: completion) }
                    }
                }
        }
    }

    private func finish(_ result: Result<OfflineSavedTrack, OfflineDownloadError>,
                        completion: (Result<OfflineSavedTrack, OfflineDownloadError>) -> Void) {
        isDownloading = false
        completion(result)
    }

    private func process(_ asset: SpotifyAudioAssetResolver.EncryptedAsset,
                         keyRecord: inout [UInt8], title: String, artist: String)
        -> Result<OfflineSavedTrack, OfflineDownloadError> {
        let manager = FileManager.default
        let basename = "eevee-offline-\(UUID().uuidString)"
        let ogg = manager.temporaryDirectory.appendingPathComponent(basename).appendingPathExtension("ogg")
        let wav = manager.temporaryDirectory.appendingPathComponent(basename).appendingPathExtension("wav")
        defer {
            _ = keyRecord.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            try? manager.removeItem(at: asset.encryptedFileURL)
            try? manager.removeItem(at: ogg)
            try? manager.removeItem(at: wav)
        }

        let decrypted = keyRecord.withUnsafeBytes { record in
            asset.encryptedFileURL.path.withCString { encryptedPath in
                ogg.path.withCString { oggPath in
                    ppc_decrypt_file_to_ogg(encryptedPath, oggPath, record.baseAddress, record.count)
                }
            }
        }
        guard decrypted == 0 else { return .failure(.decryptFailed) }
        try? manager.removeItem(at: asset.encryptedFileURL)

        let decoded = ogg.path.withCString { inputPath in
            wav.path.withCString { outputPath in
                ppc_decode_ogg_to_wav(inputPath, outputPath)
            }
        }
        guard decoded == 0 else { return .failure(.decodeFailed) }
        try? manager.removeItem(at: ogg)

        do {
            return .success(try OfflineTrackStore.shared.save(
                uri: asset.trackURI, title: title, artist: artist, stagedWAV: wav
            ))
        } catch {
            return .failure(.saveFailed(error))
        }
    }
}
