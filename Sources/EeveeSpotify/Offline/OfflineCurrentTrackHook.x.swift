import Foundation
import Orion
import ObjectiveC.runtime

struct OfflineCurrentTrackGroup: HookGroup {}

class OfflineCurrentTrackStateHook: ClassHook<NSObject> {
    typealias Group = OfflineCurrentTrackGroup
    static let targetName = "SPTEsperantoPlayer"

    func globalPlayerSubscription(_ subscription: AnyObject, gotStateUpdate state: AnyObject) {
        orig.globalPlayerSubscription(subscription, gotStateUpdate: state)
        OfflineCurrentTrack.shared.update(state: state)
    }
}

func activateOfflineCurrentTrackHook() {
    guard EeveeSpotify.spotifyVersion == "9.1.88",
          let cls = NSClassFromString(OfflineCurrentTrackStateHook.targetName),
          class_getInstanceMethod(cls, Selector(("globalPlayerSubscription:gotStateUpdate:"))) != nil else { return }
    OfflineCurrentTrackGroup().activate()
}
