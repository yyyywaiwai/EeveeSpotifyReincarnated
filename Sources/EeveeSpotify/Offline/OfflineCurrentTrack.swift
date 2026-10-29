import Foundation

/// The song reported by Spotify's live player observer, not the item of an
/// album/playlist page or a lyric lookup for a different track.
final class OfflineCurrentTrack {
    struct Snapshot: Equatable {
        let uri: String
        let title: String
        let artist: String
    }

    static let shared = OfflineCurrentTrack()
    static let changedNotification = Notification.Name("EeveeOfflineCurrentTrackChanged")

    private let lock = NSLock()
    private var current: Snapshot?

    private init() {}

    func snapshot() -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func update(state: AnyObject) {
        let next = Self.read(state: state)
        lock.lock()
        let changed = current != next
        current = next
        lock.unlock()
        if changed {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.changedNotification, object: nil)
            }
        }
    }

    private static func read(state: AnyObject) -> Snapshot? {
        guard let track = value("track", from: state) as AnyObject?,
              let uri = uriString(value("URI", from: track)),
              SpotifyAudioAssetResolver.isCanonicalTrackURI(uri),
              let title = value("trackTitle", from: track) as? String,
              let artist = value("artistName", from: track) as? String else { return nil }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanArtist.isEmpty else { return nil }
        return Snapshot(uri: uri, title: cleanTitle, artist: cleanArtist)
    }

    private static func value(_ selector: String, from object: AnyObject) -> Any? {
        guard object.responds(to: Selector(selector)) else { return nil }
        return object.value(forKey: selector)
    }

    private static func uriString(_ value: Any?) -> String? {
        if let uri = value as? URL { return uri.absoluteString }
        return value as? String
    }
}
