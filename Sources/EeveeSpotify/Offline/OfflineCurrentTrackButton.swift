import EeveeSpotifyC
import UIKit

/// A one-song action in Now Playing. It deliberately does not reuse Spotify's
/// album/playlist download button, whose action promises an entire collection.
@available(iOS 15.0, *)
enum OfflineCurrentTrackButton {
    private static let size: CGFloat = 36
    private static var saving = false
    private static var savedURI: String?
    private static var checkedURI: String?
    private static var lookupPending = false
    private static var lookupVersion = 0
    private static let lookupQueue = DispatchQueue(label: "com.eeveespotify.offline-save-state", qos: .utility)
    private static var safelyPlaced = false
    private static weak var row: UIStackView?

    private static let button: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "arrow.down.to.line")
        configuration.baseForegroundColor = .white
        configuration.background.backgroundColor = UIColor(white: 1, alpha: 0.15)
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        let control = UIButton(configuration: configuration)
        control.overrideUserInterfaceStyle = .dark
        control.accessibilityIdentifier = "EeveeOfflineCurrentTrackSave"
        control.accessibilityLabel = "offline_save_current_track".localized
        control.accessibilityHint = "offline_save_current_track_hint".localized
        control.addAction(UIAction { _ in saveCurrentTrack() }, for: .primaryActionTriggered)
        return control
    }()

    private static let observers: [NSObjectProtocol] = [
        NotificationCenter.default.addObserver(
            forName: OfflineCurrentTrack.changedNotification, object: nil, queue: .main
        ) { _ in
            if checkedURI != OfflineCurrentTrack.shared.snapshot()?.uri { refreshSavedState() }
            else { updateAppearance() }
        },
        NotificationCenter.default.addObserver(
            forName: OfflineTrackStore.changedNotification, object: nil, queue: .main
        ) { _ in refreshSavedState() }
    ]

    static func attach(to root: UIView) {
        _ = observers
        safelyPlaced = false
        if checkedURI != OfflineCurrentTrack.shared.snapshot()?.uri { refreshSavedState() }
        guard root.bounds.width >= 320 else { button.isHidden = true; return }
        if row?.isDescendant(of: root) != true {
            row = root.eeveeFirst(UIStackView.self, where: {
                $0.axis == .horizontal && $0.arrangedSubviews.count >= 2 &&
                    $0.bounds.width >= root.bounds.width * 0.65
            })
        }
        guard let row else { button.isHidden = true; return }

        // The right-hand actions abut; use the clear gap after the left action.
        // Never move native actions or obscure the central karaoke control.
        let occupied = row.arrangedSubviews.filter {
            !$0.isHidden && $0.alpha > 0.01 && $0.bounds.height >= 24
        }
            .map { $0.convert($0.bounds, to: root) }
        guard let left = occupied.min(by: { $0.midX < $1.midX }), left.width <= 80 else {
            button.isHidden = true
            return
        }
        let frame = CGRect(x: left.maxX + 8, y: left.midY - size / 2,
                           width: size, height: size)
        let overlapsNative = occupied.contains { $0.insetBy(dx: -4, dy: -4).intersects(frame) }
        let overlapsOverlay = root.subviews.contains {
            $0 !== button && $0 is UIControl && !$0.isHidden && $0.alpha > 0.01 &&
                $0.frame.insetBy(dx: -6, dy: -6).intersects(frame)
        }
        guard root.bounds.contains(frame),
              !overlapsNative, !overlapsOverlay else {
            button.isHidden = true
            return
        }

        if button.superview !== root { root.addSubview(button) }
        else if root.subviews.last !== button { root.bringSubviewToFront(button) }
        if button.frame != frame { button.frame = frame }
        safelyPlaced = true
        updateAppearance()
    }

    private static func refreshSavedState() {
        let uri = OfflineCurrentTrack.shared.snapshot()?.uri
        checkedURI = uri
        savedURI = nil
        lookupPending = uri != nil
        lookupVersion += 1
        let version = lookupVersion
        updateAppearance()
        guard let uri else { return }
        lookupQueue.async {
            let saved = (try? OfflineTrackStore.shared.fileURL(for: uri)) != nil
            DispatchQueue.main.async {
                guard version == lookupVersion,
                      checkedURI == uri,
                      OfflineCurrentTrack.shared.snapshot()?.uri == uri else { return }
                lookupPending = false
                savedURI = saved ? uri : nil
                updateAppearance()
            }
        }
    }

    private static func updateAppearance() {
        let track = OfflineCurrentTrack.shared.snapshot()
        let saved = track?.uri == savedURI
        button.isHidden = track == nil || !safelyPlaced || button.superview == nil
        button.isEnabled = track != nil && checkedURI == track?.uri && !saving && !saved && !lookupPending
        button.alpha = saving || lookupPending ? 0.6 : 1
        var configuration = button.configuration
        let symbol = saving || lookupPending ? "hourglass" : (saved ? "checkmark" : "arrow.down.to.line")
        configuration?.image = UIImage(systemName: symbol)
        button.configuration = configuration
        button.accessibilityLabel = saving ? "offline_save_in_progress".localized :
            (lookupPending ? "offline_save_checking".localized :
                (saved ? "offline_saved_current_track".localized : "offline_save_current_track".localized))
        button.accessibilityHint = saving || lookupPending ? "" :
            (saved ? "offline_saved_current_track_hint".localized : "offline_save_current_track_hint".localized)
    }

    private static func saveCurrentTrack() {
        guard !saving, !lookupPending, let track = OfflineCurrentTrack.shared.snapshot(),
              checkedURI == track.uri, track.uri != savedURI else { return }
        guard ppkc_install() != 0 else {
            showMessage("offline_save_key_unavailable")
            return
        }
        guard ppkc_generation() > 0 else {
            showMessage("offline_save_play_first")
            return
        }
        saving = true
        updateAppearance()

        OfflineDownloadCoordinator.shared.download(
            trackURI: track.uri, title: track.title, artist: track.artist
        ) { result in
            saving = false
            switch result {
            case .success:
                refreshSavedState()
                showMessage("offline_save_complete")
            case .failure(let error):
                writeDebugLog("[Offline] Current-track save failed: \(error)")
                if case .noPlaybackKey = error {
                    showMessage("offline_save_play_first")
                } else {
                    showMessage("offline_save_failed")
                }
            }
            updateAppearance()
        }
    }

    private static func showMessage(_ key: String) {
        PopUpHelper.showPopUp(message: key.localized, buttonText: "OK")
    }
}
