#if EEVEE_OFFLINE_PREFETCH_PROOF
import Foundation

// This fixed, one-shot device proof is excluded from normal deb and IPA builds.
private enum OfflinePrefetchProof {
    static let currentURI = "spotify:track:1hu2s7qkm5bo03eODpRQO3"
    static let targetURI = "spotify:track:6XYbMGvtl6tlPoGWaiH7EY"
    static var state: Int32 = 0 // Main-thread only: 0 idle, 1 running, 2 saved, negative failed.
}

@_cdecl("eevee_offline_prefetch_proof_once")
public func eeveeOfflinePrefetchProofOnce() -> Int32 {
    guard Thread.isMainThread else { return -1 }
    if OfflinePrefetchProof.state != 0 { return OfflinePrefetchProof.state }
    guard EeveeSpotify.spotifyVersion == "9.1.88" else { return -2 }
    guard OfflineCurrentTrack.shared.snapshot()?.uri == OfflinePrefetchProof.currentURI else { return -3 }
    do {
        guard try OfflineTrackStore.shared.fileURL(for: OfflinePrefetchProof.targetURI) == nil else { return -4 }
    } catch {
        return -5
    }

    OfflinePrefetchProof.state = 1
    OfflineDownloadCoordinator.shared.download(
        trackURI: OfflinePrefetchProof.targetURI, title: "Baby Be Mine", artist: "Michael Jackson"
    ) { result in
        switch result {
        case .success(let saved):
            OfflinePrefetchProof.state = saved.uri == OfflinePrefetchProof.targetURI ? 2 : -8
        case .failure(.noPlaybackKey):
            OfflinePrefetchProof.state = -6
        case .failure:
            OfflinePrefetchProof.state = -7
        }
    }
    return OfflinePrefetchProof.state
}
#endif
