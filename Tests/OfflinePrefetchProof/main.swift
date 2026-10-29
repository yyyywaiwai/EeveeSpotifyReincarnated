import Foundation

struct OfflineSavedTrack { let uri: String }
enum OfflineDownloadError: Error { case noPlaybackKey, other }

enum EeveeSpotify { static var spotifyVersion = "9.1.88" }

final class OfflineCurrentTrack {
    struct Snapshot { let uri: String }
    static let shared = OfflineCurrentTrack()
    var uri: String? = "spotify:track:1hu2s7qkm5bo03eODpRQO3"
    func snapshot() -> Snapshot? { uri.map(Snapshot.init(uri:)) }
}

enum StoreError: Error { case invalidIndex }
final class OfflineTrackStore {
    static let shared = OfflineTrackStore()
    var saved = false
    var throwsOnRead = false
    func fileURL(for uri: String) throws -> URL? {
        if throwsOnRead { throw StoreError.invalidIndex }
        return saved ? URL(fileURLWithPath: "/already-saved.wav") : nil
    }
}

final class OfflineDownloadCoordinator {
    static let shared = OfflineDownloadCoordinator()
    var calls = 0
    var arguments: (String, String, String)?
    var completion: ((Result<OfflineSavedTrack, OfflineDownloadError>) -> Void)?
    func download(trackURI: String, title: String, artist: String,
                  completion: @escaping (Result<OfflineSavedTrack, OfflineDownloadError>) -> Void) {
        calls += 1
        arguments = (trackURI, title, artist)
        self.completion = completion
    }
}

let scenario = CommandLine.arguments[1]
switch scenario {
case "wrong-version":
    EeveeSpotify.spotifyVersion = "9.1.87"
    precondition(eeveeOfflinePrefetchProofOnce() == -2)
case "wrong-thread":
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        precondition(eeveeOfflinePrefetchProofOnce() == -1)
        done.signal()
    }
    precondition(done.wait(timeout: .now() + 2) == .success)
case "wrong-track":
    OfflineCurrentTrack.shared.uri = "spotify:track:0123456789ABCDEFGHIJKL"
    precondition(eeveeOfflinePrefetchProofOnce() == -3)
case "already-saved":
    OfflineTrackStore.shared.saved = true
    precondition(eeveeOfflinePrefetchProofOnce() == -4)
case "invalid-store":
    OfflineTrackStore.shared.throwsOnRead = true
    precondition(eeveeOfflinePrefetchProofOnce() == -5)
case "success", "no-key", "other-failure", "wrong-saved-uri":
    precondition(eeveeOfflinePrefetchProofOnce() == 1)
    precondition(eeveeOfflinePrefetchProofOnce() == 1)
    let call = OfflineDownloadCoordinator.shared
    precondition(call.calls == 1)
    precondition(call.arguments?.0 == "spotify:track:6XYbMGvtl6tlPoGWaiH7EY")
    precondition(call.arguments?.1 == "Baby Be Mine")
    precondition(call.arguments?.2 == "Michael Jackson")
    switch scenario {
    case "success":
        call.completion?(.success(OfflineSavedTrack(uri: call.arguments!.0)))
        precondition(eeveeOfflinePrefetchProofOnce() == 2)
    case "no-key":
        call.completion?(.failure(.noPlaybackKey))
        precondition(eeveeOfflinePrefetchProofOnce() == -6)
    case "other-failure":
        call.completion?(.failure(.other))
        precondition(eeveeOfflinePrefetchProofOnce() == -7)
    default:
        call.completion?(.success(OfflineSavedTrack(uri: "spotify:track:0123456789ABCDEFGHIJKL")))
        precondition(eeveeOfflinePrefetchProofOnce() == -8)
    }
default:
    fatalError("unknown scenario")
}
precondition(OfflineDownloadCoordinator.shared.calls == (scenario == "success" || scenario == "no-key" || scenario == "other-failure" || scenario == "wrong-saved-uri" ? 1 : 0))
print("OfflinePrefetchProof \(scenario) passed")
