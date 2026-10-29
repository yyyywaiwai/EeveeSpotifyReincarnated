import EeveeSpotifyC
import Foundation
import ObjectiveC.runtime
import Orion
import UIKit

private protocol OfflineNativeActionBinding: AnyObject {
    func deactivate()
    func handleTap() -> Bool
}

struct OfflineNativeSingleAlbumButtonGroup: HookGroup {}
struct OfflineNativePlaylistActionVisibilityGroup: HookGroup {}

/// Spotify 9.1.88's actual page host; no global UIView/UIButton visibility hooks.
@available(iOS 15.0, *)
class OfflineNativeAlbumPageHook: ClassHook<UIViewController> {
    typealias Group = OfflineNativeSingleAlbumButtonGroup
    static let targetName = "_TtC33Navigation_PageAPIIntegrationImpl33MusicAppPageHostingViewController"

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        let host = target
        let epoch = OfflineNativeSingleAlbumButton.beginAppearance(on: host)
        for delay in [0.3, 0.8, 1.6, 3.0, 6.0, 10.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak host] in
                guard let host else { return }
                OfflineNativeSingleAlbumButton.prepare(on: host, epoch: epoch)
            }
        }
    }

    func viewDidDisappear(_ animated: Bool) {
        OfflineNativeSingleAlbumButton.detach(from: target)
        orig.viewDidDisappear(animated)
    }
}

/// TouchUpInside already targets this object. Intercept only an exact page-bound Eevee action.
@available(iOS 15.0, *)
class OfflineNativeGranularActionHook: ClassHook<NSObject> {
    typealias Group = OfflineNativeSingleAlbumButtonGroup
    static let targetName = "_TtCOOOE32EncoreConsumerMobile_ElementsKitO19LegacyUI_ECMCoreKit10Components22GranularDownloadButton2UI7Private22GranularDownloadButton"

    func performAction() {
        if OfflineNativeSingleAlbumButton.performAction(owner: target) { return }
        orig.performAction()
    }
}

/// Retry only when Spotify hides the exact playlist action after page appearance.
@available(iOS 15.0, *)
class OfflineNativePlaylistActionVisibilityHook: ClassHook<UIView> {
    typealias Group = OfflineNativePlaylistActionVisibilityGroup
    static let targetName = "_TtC35ListUXPlatform_FreeTierPlaylistImplP33_0FBF7F603415652909A2EEC13496CA7D10ActionView"

    func setHidden(_ hidden: Bool) {
        orig.setHidden(hidden)
        if hidden && target.isHidden {
            OfflineNativeSingleAlbumButton.scheduleHiddenPlaylistReconcile(for: target)
        }
    }
}

func activateOfflineNativeSingleAlbumButton() {
    guard #available(iOS 15.0, *),
          EeveeSpotify.spotifyVersion == "9.1.88",
          Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "918802209",
          let page = NSClassFromString(OfflineNativeAlbumPageHook.targetName),
          let owner = NSClassFromString(OfflineNativeGranularActionHook.targetName),
          class_getInstanceMethod(page, #selector(UIViewController.viewDidAppear(_:))) != nil,
          class_getInstanceMethod(page, #selector(UIViewController.viewDidDisappear(_:))) != nil,
          class_getInstanceMethod(page, Selector(("URI"))) != nil,
          class_getInstanceMethod(owner, Selector(("performAction"))) != nil,
          class_getInstanceMethod(owner, Selector(("uiView"))) != nil else { return }
    OfflineNativeSingleAlbumButtonGroup().activate()
    writeDebugLog("[Offline] Native collection button hooks activated")
    OfflineNativeSingleAlbumButton.activateVisibilityHookIfNeeded()
}

@available(iOS 15.0, *)
private enum OfflineNativeSingleAlbumButton {
    private static var pageStateKey: UInt8 = 0
    private static var ownerBindingKey: UInt8 = 0
    private static var appearanceEpochKey: UInt8 = 0
    private static let ownerClass = OfflineNativeGranularActionHook.targetName
    private static let hostClass = OfflineNativeAlbumPageHook.targetName
    private static let indexQueue = DispatchQueue(label: "com.eeveespotify.native-album-index", qos: .utility)
    private static let playlistActionClass = OfflineNativePlaylistActionVisibilityHook.targetName
    private static var visibilityHookActivated = false
    private static var activeBatch: BatchState?
    // shortcut: only the latest batch result survives page switches; persist per-URI history if needed.
    private static var lastBatch: BatchSummary?

    static func activateVisibilityHookIfNeeded() {
        guard Thread.isMainThread, !visibilityHookActivated,
              let playlistAction = NSClassFromString(playlistActionClass),
              class_getInstanceMethod(playlistAction, Selector(("setHidden:"))) != nil else { return }
        visibilityHookActivated = true
        OfflineNativePlaylistActionVisibilityGroup().activate()
        writeDebugLog("[Offline] Native playlist visibility hook activated")
    }

    static func beginAppearance(on host: UIViewController) -> Int {
        let next = epoch(on: host) &+ 1
        if let state = objc_getAssociatedObject(host, &pageStateKey) as? PageState {
            state.binding?.deactivate()
            objc_setAssociatedObject(host, &pageStateKey, nil, .OBJC_ASSOCIATION_ASSIGN)
        }
        objc_setAssociatedObject(host, &appearanceEpochKey, NSNumber(value: next), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return next
    }

    private static func epoch(on host: UIViewController) -> Int {
        (objc_getAssociatedObject(host, &appearanceEpochKey) as? NSNumber)?.intValue ?? 0
    }

    private final class PageState {
        let uri: String
        let kind: OfflineCollectionCatalog.Kind
        var attempted = false // One network attempt per appearance; detach resets for the next opening.
        var missingCredentialLogged = false
        var binding: OfflineNativeActionBinding?
        init(uri: String, kind: OfflineCollectionCatalog.Kind) {
            self.uri = uri
            self.kind = kind
        }
    }

    private final class Binding: OfflineNativeActionBinding {
        weak var host: UIViewController?
        weak var button: UIButton?
        weak var parent: UIView?
        weak var owner: NSObject?
        weak var stateAnimationView: UIView?
        let albumURI: String
        let trackURI: String
        let appearanceEpoch: Int
        let originalButtonHidden: Bool
        let originalParentHidden: Bool
        let originalInteraction: Bool
        let originalEnabled: Bool
        let originalAlpha: CGFloat
        let originalConfiguration: UIButton.Configuration?
        let originalNormalImage: UIImage?
        let originalAnimationHidden: Bool
        let originalAccessibilityLabel: String?
        let originalAccessibilityValue: String?
        let originalAccessibilityHint: String?
        private var saved = false
        private var lookupPending = true
        private var saving = false
        private var completionPending = false
        private var active = true
        private var revealed = false
        private var lookupVersion = 0
        private var storeObserver: NSObjectProtocol?

        init(host: UIViewController, button: UIButton, owner: NSObject, stateAnimationView: UIView,
             albumURI: String, trackURI: String, appearanceEpoch: Int) {
            self.host = host
            self.button = button
            self.parent = button.superview
            self.owner = owner
            self.stateAnimationView = stateAnimationView
            self.albumURI = albumURI
            self.trackURI = trackURI
            self.appearanceEpoch = appearanceEpoch
            originalButtonHidden = button.isHidden
            originalParentHidden = button.superview?.isHidden ?? true
            originalInteraction = button.isUserInteractionEnabled
            originalEnabled = button.isEnabled
            originalAlpha = button.alpha
            originalConfiguration = button.configuration
            originalNormalImage = button.image(for: .normal)
            originalAnimationHidden = stateAnimationView.isHidden
            originalAccessibilityLabel = button.accessibilityLabel
            originalAccessibilityValue = button.accessibilityValue
            originalAccessibilityHint = button.accessibilityHint
            storeObserver = NotificationCenter.default.addObserver(
                forName: OfflineTrackStore.changedNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.refreshIndex() }
        }

        deinit {
            if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        }

        func deactivate() {
            guard active else { return }
            active = false
            lookupVersion &+= 1
            if let button, let parent, button.superview === parent {
                UIView.performWithoutAnimation {
                    button.isHidden = originalButtonHidden
                    parent.isHidden = originalParentHidden
                    button.isUserInteractionEnabled = originalInteraction
                    button.isEnabled = originalEnabled
                    button.alpha = originalAlpha
                    button.configuration = originalConfiguration
                    button.setImage(originalNormalImage, for: .normal)
                    if let stateAnimationView, stateAnimationView.superview === button {
                        stateAnimationView.isHidden = originalAnimationHidden
                    }
                    button.accessibilityLabel = originalAccessibilityLabel
                    button.accessibilityValue = originalAccessibilityValue
                    button.accessibilityHint = originalAccessibilityHint
                    host?.viewIfLoaded?.layoutIfNeeded()
                }
            }
            if let owner { objc_setAssociatedObject(owner, &ownerBindingKey, nil, .OBJC_ASSOCIATION_ASSIGN) }
        }

        private func isCurrentPage() -> Bool {
            guard active, let host, let button, let parent, let owner,
                  let root = host.viewIfLoaded, root.window?.isKeyWindow == true,
                  button.window === root.window, button.isDescendant(of: root),
                  parent === button.superview,
                  OfflineNativeSingleAlbumButton.epoch(on: host) == appearanceEpoch,
                  OfflineNativeSingleAlbumButton.albumURI(for: host) == albumURI,
                  OfflineNativeSingleAlbumButton.hasActionTarget(button, owner: owner) else { return false }
            return true
        }

        func refreshIndex() {
            guard active else { return }
            lookupVersion &+= 1
            let version = lookupVersion
            lookupPending = true
            updatePresentation()
            indexQueue.async { [weak self] in
                guard let self else { return }
                let valid = (try? OfflineTrackStore.shared.fileURL(for: self.trackURI)) != nil
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.active, self.lookupVersion == version else { return }
                    self.lookupPending = false
                    self.saved = valid
                    self.updatePresentation()
                    if self.completionPending, self.isCurrentPage() {
                        self.completionPending = false
                        PopUpHelper.showPopUp(message: (valid ? "offline_save_complete" : "offline_save_failed").localized,
                                              buttonText: "OK")
                    }
                }
            }
        }

        func handleTap() -> Bool {
            guard isCurrentPage(), let button, !button.isHidden,
                  parent?.isHidden == false else { return false }
            if lookupPending || saving || saved { return true }
            guard let current = OfflineCurrentTrack.shared.snapshot(),
                  current.uri == trackURI, ppkc_generation() > 0 else {
                PopUpHelper.showPopUp(message: "offline_save_play_first".localized,
                                      buttonText: "OK")
                return true
            }
            saving = true
            updatePresentation()
            OfflineDownloadCoordinator.shared.download(
                trackURI: trackURI, title: current.title, artist: current.artist
            ) { [weak self] result in
                guard let self, self.active else { return }
                self.saving = false
                switch result {
                case .success(let entry) where entry.uri == self.trackURI:
                    self.completionPending = true
                    self.refreshIndex()
                case .failure(.noPlaybackKey):
                    self.updatePresentation()
                    PopUpHelper.showPopUp(message: "offline_save_play_first".localized,
                                          buttonText: "OK")
                default:
                    self.updatePresentation()
                    PopUpHelper.showPopUp(message: "offline_save_failed".localized,
                                          buttonText: "OK")
                }
            }
            return true
        }

        private func updatePresentation() {
            guard isCurrentPage(), let button, let parent, let root = host?.viewIfLoaded else { return }
            if !revealed {
                guard OfflineNativeSingleAlbumButton.revealAndValidate(button: button,
                                                                         parent: parent, root: root) else {
                    writeDebugLog("[Offline] Native album layout/hit gate failed")
                    deactivate()
                    return
                }
                revealed = true
                writeDebugLog("[Offline] Native album button revealed after layout/hit validation")
            } else if !OfflineNativeSingleAlbumButton.geometryPostSafe(button: button,
                                                                        parent: parent, root: root) {
                deactivate()
                return
            }
            button.isUserInteractionEnabled = true
            button.isEnabled = !lookupPending && !saving && !saved
            button.alpha = lookupPending || saving ? 0.6 : 1
            button.accessibilityLabel = saved ? "offline_saved_current_track".localized :
                (saving ? "offline_save_in_progress".localized : "offline_save_current_track".localized)
            button.accessibilityValue = saved ? "offline_saved_current_track".localized : nil
            button.accessibilityHint = saved ? "offline_saved_current_track_hint".localized : nil
            let symbol = UIImage(systemName: saved ? "checkmark.circle.fill" : "arrow.down.to.line")
            if var configuration = button.configuration {
                configuration.image = symbol
                button.configuration = configuration
            } else {
                button.setImage(symbol, for: .normal)
            }
            // Spotify's Lottie state sits above UIButton's image; expose the verified local check only after save.
            if let stateAnimationView, stateAnimationView.superview === button {
                stateAnimationView.isHidden = saved || originalAnimationHidden
            }
        }
    }

    private final class BatchState {
        let uri: String
        let trackURIs: [String]
        let plannedCount: Int
        var id: UUID?
        var processedCount = 0
        var cancelRequested = false
        weak var binding: BulkBinding?

        init(collection: OfflineCollectionCatalog.Collection, binding: BulkBinding) {
            uri = collection.uri
            trackURIs = collection.trackURIs
            plannedCount = collection.uniqueTracks.count
            self.binding = binding
        }

        func matches(_ collection: OfflineCollectionCatalog.Collection) -> Bool {
            uri == collection.uri && trackURIs == collection.trackURIs
        }
    }

    private struct BatchSummary {
        let uri: String
        let trackURIs: [String]
        let plannedCount: Int
        let savedCount: Int
        let failedCount: Int
        let unstartedCount: Int
        let complete: Bool
        let stopReason: OfflineCollectionDownloadResult.StopReason?
        let collectionCheck: OfflineCollectionDownloadResult.CollectionCheck

        init(collection: OfflineCollectionCatalog.Collection,
             result: OfflineCollectionDownloadResult) {
            uri = collection.uri
            trackURIs = collection.trackURIs
            plannedCount = result.plannedCount
            savedCount = result.items.filter {
                if case .failed = $0.outcome { return false }
                return true
            }.count
            failedCount = result.items.count - savedCount
            unstartedCount = max(0, result.plannedCount - result.items.count)
            complete = result.isComplete
            stopReason = result.stopReason
            collectionCheck = result.collectionCheck
            assert(savedCount + failedCount + unstartedCount == plannedCount)
        }

        func matches(_ collection: OfflineCollectionCatalog.Collection) -> Bool {
            uri == collection.uri && trackURIs == collection.trackURIs
        }

        var message: String {
            if complete {
                return String(format: "offline_collection_complete".localized, savedCount, plannedCount)
            }
            let key: String
            switch stopReason {
            case .userCancelled: key = "offline_collection_cancelled"
            case .deadlineExceeded: key = "offline_collection_deadline"
            case nil:
                switch collectionCheck {
                case .changed: key = "offline_collection_changed"
                case .unavailable: key = "offline_collection_unavailable"
                default: key = "offline_collection_partial"
                }
            }
            return String(format: key.localized,
                          savedCount, plannedCount, failedCount, unstartedCount)
        }
    }

    private final class BulkBinding: OfflineNativeActionBinding {
        weak var host: UIViewController?
        weak var button: UIButton?
        weak var parent: UIView?
        weak var owner: NSObject?
        weak var stateAnimationView: UIView?
        weak var playlistAction: UIView?
        let collection: OfflineCollectionCatalog.Collection
        let appearanceEpoch: Int
        let originalButtonHidden: Bool
        let originalParentHidden: Bool
        let originalActionHidden: Bool?
        let originalInteraction: Bool
        let originalEnabled: Bool
        let originalAlpha: CGFloat
        let originalConfiguration: UIButton.Configuration?
        let originalNormalImage: UIImage?
        let originalAnimationHidden: Bool?
        let originalAccessibilityLabel: String?
        let originalAccessibilityValue: String?
        let originalAccessibilityHint: String?
        private var saved = false
        private var lookupFailed = false
        private var lookupPending = true
        private var pendingSummary: BatchSummary?
        private var active = true
        private var revealed = false
        private var lateReconcilePending = false
        private var lookupVersion = 0
        private var storeObserver: NSObjectProtocol?

        init(host: UIViewController, button: UIButton, owner: NSObject,
             stateAnimationView: UIView?, playlistAction: UIView?,
             collection: OfflineCollectionCatalog.Collection, appearanceEpoch: Int) {
            self.host = host
            self.button = button
            parent = button.superview
            self.owner = owner
            self.stateAnimationView = stateAnimationView
            self.playlistAction = playlistAction
            self.collection = collection
            self.appearanceEpoch = appearanceEpoch
            originalButtonHidden = button.isHidden
            originalParentHidden = button.superview?.isHidden ?? true
            originalActionHidden = playlistAction?.isHidden
            originalInteraction = button.isUserInteractionEnabled
            originalEnabled = button.isEnabled
            originalAlpha = button.alpha
            originalConfiguration = button.configuration
            originalNormalImage = button.image(for: .normal)
            originalAnimationHidden = stateAnimationView?.isHidden
            originalAccessibilityLabel = button.accessibilityLabel
            originalAccessibilityValue = button.accessibilityValue
            originalAccessibilityHint = button.accessibilityHint
            if let job = OfflineNativeSingleAlbumButton.activeBatch, job.matches(collection) {
                job.binding = self
            }
            storeObserver = NotificationCenter.default.addObserver(
                forName: OfflineTrackStore.changedNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                // Each saved track posts a notification; read the full index only after the batch ends.
                if OfflineNativeSingleAlbumButton.activeBatch == nil {
                    self.refreshIndex()
                }
            }
        }

        deinit {
            if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        }

        func deactivate() {
            guard active else { return }
            active = false
            lookupVersion &+= 1
            UIView.performWithoutAnimation {
                if let button, let parent, button.superview === parent {
                    button.isHidden = originalButtonHidden
                    parent.isHidden = originalParentHidden
                    button.isUserInteractionEnabled = originalInteraction
                    button.isEnabled = originalEnabled
                    button.alpha = originalAlpha
                    button.configuration = originalConfiguration
                    button.setImage(originalNormalImage, for: .normal)
                    if let stateAnimationView, stateAnimationView.superview === button,
                       let originalAnimationHidden {
                        stateAnimationView.isHidden = originalAnimationHidden
                    }
                    button.accessibilityLabel = originalAccessibilityLabel
                    button.accessibilityValue = originalAccessibilityValue
                    button.accessibilityHint = originalAccessibilityHint
                }
                if let action = playlistAction, let root = host?.viewIfLoaded,
                   action.isDescendant(of: root), let originalActionHidden,
                   let row = action.superview as? UIStackView,
                   row.arrangedSubviews.contains(where: { $0 === action }) {
                    action.isHidden = originalActionHidden
                }
                host?.viewIfLoaded?.layoutIfNeeded()
            }
            if let owner { objc_setAssociatedObject(owner, &ownerBindingKey, nil, .OBJC_ASSOCIATION_ASSIGN) }
            if let job = OfflineNativeSingleAlbumButton.activeBatch, job.binding === self {
                job.binding = nil
            }
        }

        private func isCurrentPage() -> Bool {
            guard active, let host, let button, let parent, let owner,
                  let root = host.viewIfLoaded, root.window?.isKeyWindow == true,
                  button.window === root.window, button.isDescendant(of: root),
                  parent === button.superview,
                  OfflineNativeSingleAlbumButton.epoch(on: host) == appearanceEpoch,
                  OfflineNativeSingleAlbumButton.pageURI(for: host)?.0 == collection.uri,
                  OfflineNativeSingleAlbumButton.hasActionTarget(button, owner: owner) else { return false }
            if collection.kind == .playlist {
                guard let action = playlistAction, action === parent.superview else { return false }
            }
            return true
        }

        func reconcileScheduledAppearance(on currentHost: UIViewController,
                                          state: PageState, epoch: Int) {
            guard collection.kind == .playlist, host === currentHost,
                  appearanceEpoch == epoch, let button, let owner,
                  let associated = objc_getAssociatedObject(owner, &ownerBindingKey) as? BulkBinding,
                  associated === self,
                  OfflineNativeSingleAlbumButton.currentState(host: currentHost, state: state,
                                                                button: button, owner: owner,
                                                                epoch: epoch) != nil,
                  isCurrentPage() else { return }
            updatePresentation()
        }

        func scheduleHiddenReconcile() {
            guard active, !lateReconcilePending else { return }
            lateReconcilePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Keep the retry coalesced through a failed reveal's hidden-state rollback.
                defer { self.lateReconcilePending = false }
                guard self.active, self.playlistAction?.isHidden == true,
                      let host = self.host,
                      let state = objc_getAssociatedObject(
                        host, &OfflineNativeSingleAlbumButton.pageStateKey
                      ) as? PageState else { return }
                self.reconcileScheduledAppearance(on: host, state: state,
                                                  epoch: self.appearanceEpoch)
            }
        }

        private func revealPlaylistPreservingEnabled(button: UIButton, parent: UIView,
                                                     action: UIView, root: UIView) -> Bool {
            let wasEnabled = button.isEnabled
            defer { button.isEnabled = wasEnabled }
            // UIKit hitTest needs the button enabled; defer restores saved/index-pending state.
            button.isEnabled = true
            return OfflineNativeSingleAlbumButton.playlistRevealAndValidate(
                button: button, parent: parent, action: action, root: root)
        }

        func refreshIndex() {
            guard active else { return }
            if OfflineNativeSingleAlbumButton.activeBatch?.binding === self {
                lookupPending = false
                updatePresentation()
                return
            }
            lookupVersion &+= 1
            let version = lookupVersion
            lookupPending = true
            updatePresentation()
            let wanted = Set(collection.uniqueTrackURIs)
            indexQueue.async { [weak self] in
                guard let self else { return }
                let read: Result<Bool, Error> = Result {
                    let saved = Set(try OfflineTrackStore.shared.tracks().map(\.uri))
                    return wanted.isSubset(of: saved)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.active, self.lookupVersion == version else { return }
                    self.lookupPending = false
                    switch read {
                    case .success(let valid):
                        if let last = OfflineNativeSingleAlbumButton.lastBatch,
                           last.matches(self.collection), !last.complete {
                            self.saved = false
                        } else {
                            self.saved = valid
                        }
                        self.lookupFailed = false
                    case .failure:
                        self.saved = false
                        self.lookupFailed = true
                    }
                    self.updatePresentation()
                    if let summary = self.pendingSummary, self.isCurrentPage() {
                        self.pendingSummary = nil
                        let message = summary.complete && self.saved ? summary.message :
                            (summary.complete ? "offline_collection_verify_failed".localized : summary.message)
                        PopUpHelper.showPopUp(message: message, buttonText: "OK")
                    }
                }
            }
        }

        func handleTap() -> Bool {
            guard isCurrentPage(), let button, let parent, let root = host?.viewIfLoaded,
                  !button.isHidden, !parent.isHidden else { return false }
            if collection.kind == .playlist {
                guard revealed, let action = playlistAction, !action.isHidden,
                      OfflineNativeSingleAlbumButton.playlistGeometryPostSafe(
                        button: button, parent: parent, action: action, root: root) else { return false }
            }
            if let job = OfflineNativeSingleAlbumButton.activeBatch, job.binding === self {
                if !job.cancelRequested, job.processedCount < job.plannedCount, let id = job.id {
                    job.cancelRequested = true
                    OfflineDownloadCoordinator.shared.cancelCollection(id: id)
                    updatePresentation()
                }
                return true
            }
            if lookupPending || saved || lookupFailed { return true }
            guard OfflineNativeSingleAlbumButton.activeBatch == nil else {
                PopUpHelper.showPopUp(message: "offline_collection_busy".localized, buttonText: "OK")
                return true
            }
            guard ppkc_generation() > 0 else {
                PopUpHelper.showPopUp(message: "offline_save_play_first".localized, buttonText: "OK")
                return true
            }
            let job = BatchState(collection: collection, binding: self)
            let scope = collection
            OfflineNativeSingleAlbumButton.activeBatch = job
            OfflineNativeSingleAlbumButton.lastBatch = nil
            updatePresentation()
            job.id = OfflineDownloadCoordinator.shared.download(
                collection: collection,
                progress: { [job] value in
                    guard OfflineNativeSingleAlbumButton.activeBatch === job else { return }
                    job.processedCount = value.processedCount
                    job.binding?.updatePresentation()
                },
                completion: { [job] result in
                    guard OfflineNativeSingleAlbumButton.activeBatch === job else { return }
                    let summary: BatchSummary?
                    switch result {
                    case .complete(let value), .partial(let value):
                        summary = BatchSummary(collection: scope, result: value)
                    case .failedToStart:
                        summary = nil
                    }
                    OfflineNativeSingleAlbumButton.activeBatch = nil
                    OfflineNativeSingleAlbumButton.lastBatch = summary
                    if let binding = job.binding {
                        binding.pendingSummary = summary
                        if summary == nil, binding.isCurrentPage() {
                            PopUpHelper.showPopUp(message: "offline_collection_failed_to_start".localized,
                                                  buttonText: "OK")
                        }
                    }
                    NotificationCenter.default.post(name: OfflineTrackStore.changedNotification,
                                                    object: nil)
                }
            )
            return true
        }

        private func updatePresentation() {
            guard isCurrentPage(), let button, let parent, let root = host?.viewIfLoaded else { return }
            if !revealed {
                let accepted: Bool
                if let action = playlistAction {
                    accepted = revealPlaylistPreservingEnabled(
                        button: button, parent: parent, action: action, root: root)
                } else {
                    accepted = OfflineNativeSingleAlbumButton.revealAndValidate(
                        button: button, parent: parent, root: root)
                }
                guard accepted else {
                    // A playlist's native header may still be settling. Keep the exact
                    // binding for the remaining scheduled appearance checks to retry.
                    if playlistAction == nil { deactivate() }
                    return
                }
                revealed = true
            } else if let action = playlistAction {
                if action.isHidden {
                    guard revealPlaylistPreservingEnabled(
                        button: button, parent: parent, action: action, root: root) else { return }
                } else {
                    guard OfflineNativeSingleAlbumButton.playlistGeometryPostSafe(
                        button: button, parent: parent, action: action, root: root) else {
                        deactivate(); return
                    }
                }
            } else if !OfflineNativeSingleAlbumButton.geometryPostSafe(button: button,
                                                                        parent: parent, root: root) {
                deactivate(); return
            }
            let job = OfflineNativeSingleAlbumButton.activeBatch
            let running = job?.binding === self
            let cancelling = running && job?.cancelRequested == true
            let verifying = running && job.map { $0.processedCount >= $0.plannedCount } == true
            button.isUserInteractionEnabled = true
            button.isEnabled = running ? !cancelling && !verifying : (!lookupPending && !lookupFailed && !saved)
            button.alpha = lookupPending || cancelling || verifying ? 0.6 : 1
            if running, let job {
                button.accessibilityLabel = (verifying ? "offline_collection_verifying" :
                    (cancelling ? "offline_collection_cancelling" :
                        "offline_collection_cancel")).localized
                button.accessibilityValue = String(format: "offline_collection_progress".localized,
                                                   job.processedCount, job.plannedCount)
                button.accessibilityHint = cancelling || verifying ? nil :
                    "offline_collection_cancel_hint".localized
            } else {
                button.accessibilityLabel = (lookupFailed ? "offline_library_read_failed" :
                    (saved ? "offline_collection_saved" : "offline_collection_save")).localized
                button.accessibilityValue = saved ? "offline_collection_saved".localized :
                    (OfflineNativeSingleAlbumButton.lastBatch?.matches(collection) == true
                        ? OfflineNativeSingleAlbumButton.lastBatch?.message : nil)
                button.accessibilityHint = saved ? "offline_saved_current_track_hint".localized :
                    "offline_collection_save_hint".localized
            }
            let symbol = UIImage(systemName: saved ? "checkmark.circle.fill" :
                                 (running ? "xmark.circle" : "arrow.down.to.line"))
            if var configuration = button.configuration {
                configuration.image = symbol
                button.configuration = configuration
            } else {
                button.setImage(symbol, for: .normal)
            }
            if let stateAnimationView, stateAnimationView.superview === button,
               let originalAnimationHidden {
                stateAnimationView.isHidden = saved || running || originalAnimationHidden
            }
        }
    }

    static func prepare(on host: UIViewController, epoch: Int) {
        guard Thread.isMainThread, let root = host.viewIfLoaded, root.window?.isKeyWindow == true,
              self.epoch(on: host) == epoch,
              let hostType = NSClassFromString(hostClass), host.isKind(of: hostType),
              let (uri, kind) = pageURI(for: host) else { return }
        let state: PageState
        if let old = objc_getAssociatedObject(host, &pageStateKey) as? PageState,
           old.uri == uri, old.kind == kind {
            state = old
        } else {
            (objc_getAssociatedObject(host, &pageStateKey) as? PageState)?.binding?.deactivate()
            state = PageState(uri: uri, kind: kind)
            objc_setAssociatedObject(host, &pageStateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        if let binding = state.binding {
            if kind == .playlist, let bulk = binding as? BulkBinding {
                bulk.reconcileScheduledAppearance(on: host, state: state, epoch: epoch)
            }
            return
        }
        guard !state.attempted else { return }
        guard spotifyCatalogCredential != nil else {
            if !state.missingCredentialLogged {
                state.missingCredentialLogged = true
                writeDebugLog("[Offline] Native album waiting for paired session credential")
            }
            return
        }
        guard
              let (button, owner) = findNativeButton(in: root, validateUIView: true),
              (kind == .album
                ? geometryPreflight(button: button, parent: button.superview, root: root)
                : playlistGeometryPreflight(button: button, root: root) != nil) else { return }
        state.attempted = true
        if kind == .playlist {
            OfflineCollectionCatalog.fetch(uri: uri) { [weak host] result in
                guard let host else { return }
                bindCollection(result, host: host, state: state, button: button,
                               owner: owner, epoch: epoch)
            }
        } else {
            OfflineCollectionCatalog.fetchSingleAlbum(uri: uri) { [weak host] result in
                guard let host, currentState(host: host, state: state, button: button,
                                             owner: owner, epoch: epoch) != nil else { return }
                switch result {
                case .success(let collection):
                    guard let trackURI = collection.singleAlbumTrackURI(expectedAlbumURI: uri),
                          let root = host.viewIfLoaded,
                          geometryPreflight(button: button, parent: button.superview, root: root),
                          let animation = stateAnimationView(in: button) else { return }
                    let binding = Binding(host: host, button: button, owner: owner,
                                          stateAnimationView: animation, albumURI: uri,
                                          trackURI: trackURI, appearanceEpoch: epoch)
                    state.binding = binding
                    objc_setAssociatedObject(owner, &ownerBindingKey, binding, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                    binding.refreshIndex()
                case .failure(.ineligibleCollectionSize):
                    OfflineCollectionCatalog.fetch(uri: uri) { [weak host] fullResult in
                        guard let host else { return }
                        bindCollection(fullResult, host: host, state: state, button: button,
                                       owner: owner, epoch: epoch)
                    }
                case .failure(let error):
                    writeDebugLog("[Offline] Native album catalog rejected: \(error)")
                }
            }
        }
    }

    static func scheduleHiddenPlaylistReconcile(for action: UIView) {
        guard Thread.isMainThread,
              let (_, owner) = findNativeButton(in: action, validateUIView: false),
              let binding = objc_getAssociatedObject(owner, &ownerBindingKey) as? BulkBinding,
              binding.playlistAction === action else { return }
        binding.scheduleHiddenReconcile()
    }

    private static func currentState(host: UIViewController, state: PageState,
                                     button: UIButton, owner: NSObject, epoch: Int) -> UIView? {
        guard let root = host.viewIfLoaded, root.window?.isKeyWindow == true,
              self.epoch(on: host) == epoch,
              let current = objc_getAssociatedObject(host, &pageStateKey) as? PageState,
              current === state, current.uri == state.uri,
              pageURI(for: host)?.0 == state.uri,
              let (liveButton, liveOwner) = findNativeButton(in: root, validateUIView: false),
              liveButton === button, liveOwner === owner else { return nil }
        return root
    }

    private static func stateAnimationView(in button: UIButton) -> UIView? {
        let views = button.subviews.filter {
            let name = NSStringFromClass(type(of: $0))
            return name.contains("StateMicroInteractionView") &&
                name.contains("GranularDownloadButtonState_")
        }
        return views.count == 1 ? views[0] : nil
    }

    private static func bindCollection(_ result: Result<OfflineCollectionCatalog.Collection,
                                      OfflineCollectionCatalog.CatalogError>,
                                       host: UIViewController, state: PageState,
                                       button: UIButton, owner: NSObject, epoch: Int) {
        guard let root = currentState(host: host, state: state, button: button,
                                      owner: owner, epoch: epoch) else { return }
        guard case .success(let collection) = result,
              collection.uri == state.uri, collection.kind == state.kind,
              (state.kind == .playlist || collection.totalCount > 1),
              !collection.uniqueTracks.isEmpty else {
            if case .failure(let error) = result {
                writeDebugLog("[Offline] Native collection catalog rejected: \(error)")
            }
            return
        }
        let action: UIView?
        if state.kind == .playlist {
            guard let found = playlistGeometryPreflight(button: button, root: root) else { return }
            activateVisibilityHookIfNeeded()
            action = found
        } else {
            guard geometryPreflight(button: button, parent: button.superview, root: root) else { return }
            action = nil
        }
        let binding = BulkBinding(host: host, button: button, owner: owner,
                                  stateAnimationView: stateAnimationView(in: button), playlistAction: action,
                                  collection: collection, appearanceEpoch: epoch)
        state.binding = binding
        objc_setAssociatedObject(owner, &ownerBindingKey, binding, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        binding.refreshIndex()
    }

    static func detach(from host: UIViewController) {
        guard Thread.isMainThread else { return }
        objc_setAssociatedObject(host, &appearanceEpochKey, NSNumber(value: epoch(on: host) &+ 1),
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if let state = objc_getAssociatedObject(host, &pageStateKey) as? PageState {
            state.binding?.deactivate()
        }
        objc_setAssociatedObject(host, &pageStateKey, nil, .OBJC_ASSOCIATION_ASSIGN)
    }

    static func performAction(owner: NSObject) -> Bool {
        guard Thread.isMainThread,
              let binding = objc_getAssociatedObject(owner, &ownerBindingKey) as? OfflineNativeActionBinding else { return false }
        return binding.handleTap()
    }

    private static func pageURI(for host: UIViewController) -> (String, OfflineCollectionCatalog.Kind)? {
        guard host.responds(to: Selector(("URI"))),
              let value = host.perform(Selector(("URI")))?.takeUnretainedValue() as? URL else { return nil }
        let uri = value.absoluteString
        guard let kind = OfflineCollectionCatalog.kind(for: uri) else { return nil }
        return (uri, kind)
    }

    private static func albumURI(for host: UIViewController) -> String? {
        guard let (uri, kind) = pageURI(for: host), kind == .album else { return nil }
        return uri
    }

    private static func findNativeButton(in root: UIView,
                                         validateUIView: Bool) -> (UIButton, NSObject)? {
        var found: [(UIButton, NSObject)] = []
        var queue: [UIView] = [root]
        var index = 0
        while index < queue.count && index < 3_000 {
            let view = queue[index]
            index += 1
            if let button = view as? UIButton,
               button.accessibilityIdentifier == "DownloadButton.Granular.None",
               let owner = owner(for: button, validateUIView: validateUIView) {
                found.append((button, owner))
            }
            queue.append(contentsOf: view.subviews)
        }
        return found.count == 1 ? found[0] : nil
    }

    private static func hasActionTarget(_ button: UIButton, owner: NSObject) -> Bool {
        button.allTargets.contains { ($0.base as? NSObject) === owner } &&
            (button.actions(forTarget: owner, forControlEvent: .touchUpInside) ?? [])
                .contains("performAction")
    }

    private static func owner(for button: UIButton, validateUIView: Bool) -> NSObject? {
        let candidates = button.allTargets.compactMap { $0.base as? NSObject }.filter {
            NSStringFromClass(type(of: $0)) == ownerClass && hasActionTarget(button, owner: $0)
        }
        guard candidates.count == 1, let owner = candidates.first else { return nil }
        if validateUIView {
            guard owner.responds(to: Selector(("uiView"))),
                  let uiView = owner.perform(Selector(("uiView")))?.takeUnretainedValue() as? UIView,
                  uiView === button else { return nil }
        }
        return owner
    }

    private static func playlistGeometryPreflight(button: UIButton, root: UIView) -> UIView? {
        guard let parent = button.superview, let action = parent.superview,
              let actionType = NSClassFromString(playlistActionClass), action.isKind(of: actionType),
              let row = action.superview as? UIStackView,
              row.accessibilityIdentifier == "HeaderActionsRow",
              row.arrangedSubviews.contains(where: { $0 === action }),
              action.isHidden, !button.isHidden, !parent.isHidden,
              button.isEnabled, button.isUserInteractionEnabled,
              button.window === root.window, button.isDescendant(of: root),
              button.bounds.width >= 40, button.bounds.height >= 40,
              action.bounds.width >= 40, action.bounds.height >= 40,
              parent.alpha > 0.01, action.alpha > 0.01 else { return nil }
        var ancestor: UIView? = row
        while let view = ancestor, view !== root {
            if view.isHidden || view.alpha < 0.01 { return nil }
            ancestor = view.superview
        }
        return ancestor === root ? action : nil
    }

    private static func playlistGeometryPostSafe(button: UIButton, parent: UIView,
                                                 action: UIView, root: UIView) -> Bool {
        guard !button.isHidden, !parent.isHidden, !action.isHidden,
              button.superview === parent, parent.superview === action,
              let actionType = NSClassFromString(playlistActionClass), action.isKind(of: actionType),
              let row = action.superview as? UIStackView,
              row.accessibilityIdentifier == "HeaderActionsRow",
              row.arrangedSubviews.contains(where: { $0 === action }),
              button.window === root.window,
              root.bounds.contains(button.convert(button.bounds, to: root)),
              root.bounds.contains(action.convert(action.bounds, to: root)),
              action.bounds.contains(button.convert(button.bounds, to: action)) else { return false }
        let frame = action.convert(action.bounds, to: row)
        guard row.bounds.contains(frame) else { return false }
        for sibling in row.arrangedSubviews where sibling !== action &&
                !sibling.isHidden && sibling.alpha > 0.01 && sibling.isUserInteractionEnabled {
            if frame.intersects(sibling.convert(sibling.bounds, to: row)) { return false }
        }
        return true
    }

    private static func playlistRevealAndValidate(button: UIButton, parent: UIView,
                                                   action: UIView, root: UIView) -> Bool {
        guard playlistGeometryPreflight(button: button, root: root) === action,
              let window = root.window, window.isKeyWindow else { return false }
        var accepted = false
        defer {
            if !accepted {
                UIView.performWithoutAnimation {
                    action.isHidden = true
                    root.layoutIfNeeded()
                }
            }
        }
        UIView.performWithoutAnimation {
            action.isHidden = false
            root.layoutIfNeeded()
        }
        guard playlistGeometryPostSafe(button: button, parent: parent,
                                       action: action, root: root) else { return false }
        let center = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: window)
        accepted = window.hitTest(center, with: nil) === button
        return accepted
    }

    private static func geometryPreflight(button: UIButton, parent: UIView?, root: UIView) -> Bool {
        guard let parent, button.isHidden, parent.isHidden,
              !button.isUserInteractionEnabled else { return false }
        return geometryFrameValid(button: button, parent: parent, root: root)
    }

    private static func geometryFrameValid(button: UIButton, parent: UIView, root: UIView) -> Bool {
        guard let row = parent.superview as? UIStackView,
              button.superview === parent, button.window === root.window,
              button.bounds.width >= 40, button.bounds.height >= 40,
              parent.bounds.width >= 40, parent.bounds.height >= 40,
              row.arrangedSubviews.contains(where: { $0 === parent }) else { return false }
        let frame = button.convert(button.bounds, to: root)
        guard frame.minX.isFinite, frame.minY.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              root.bounds.contains(frame) else { return false }
        var ancestor = parent.superview
        while let view = ancestor, view !== root {
            if view.isHidden || view.alpha < 0.01 { return false }
            ancestor = view.superview
        }
        return ancestor === root
    }

    private static func geometryPostSafe(button: UIButton, parent: UIView, root: UIView) -> Bool {
        guard !button.isHidden, !parent.isHidden,
              geometryFrameValid(button: button, parent: parent, root: root),
              let row = parent.superview as? UIStackView else { return false }
        let rowFrame = button.convert(button.bounds, to: row)
        for sibling in row.arrangedSubviews where sibling !== parent &&
                !sibling.isHidden && sibling.alpha > 0.01 && sibling.isUserInteractionEnabled {
            if rowFrame.intersects(sibling.convert(sibling.bounds, to: row)) { return false }
        }
        return true
    }

    private static func revealAndValidate(button: UIButton, parent: UIView, root: UIView) -> Bool {
        guard geometryPreflight(button: button, parent: parent, root: root),
              let window = root.window, window.isKeyWindow else { return false }
        let before = (button.isHidden, parent.isHidden, button.isUserInteractionEnabled,
                      button.isEnabled, button.alpha)
        var accepted = false
        defer {
            if !accepted {
                UIView.performWithoutAnimation {
                    button.isHidden = before.0
                    parent.isHidden = before.1
                    button.isUserInteractionEnabled = before.2
                    button.isEnabled = before.3
                    button.alpha = before.4
                    root.layoutIfNeeded()
                }
            }
        }
        UIView.performWithoutAnimation {
            parent.isHidden = false
            button.isHidden = false
            button.isUserInteractionEnabled = true
            button.isEnabled = true
            button.alpha = 1
            root.layoutIfNeeded()
        }
        guard geometryPostSafe(button: button, parent: parent, root: root) else { return false }
        let center = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: window)
        accepted = window.hitTest(center, with: nil) === button
        return accepted
    }
}
