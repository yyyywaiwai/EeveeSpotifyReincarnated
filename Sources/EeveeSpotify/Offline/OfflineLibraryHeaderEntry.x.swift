import Orion
import SwiftUI
import UIKit
import ObjectiveC.runtime

struct OfflineLibraryHeaderEntryGroup: HookGroup {}

/// Spotify's My Library header in 9.1.88. This adds only an Eevee-owned
/// navigation entry; it does not change Spotify's filters or download model.
class OfflineLibraryHeaderEntryHook: ClassHook<UIView> {
    typealias Group = OfflineLibraryHeaderEntryGroup
    static let targetName = "_TtC28YourLibrary_YourLibraryXImpl21YourLibraryHeaderView"

    func layoutSubviews() {
        orig.layoutSubviews()
        OfflineLibraryHeaderEntry.attach(to: target)
        OfflineLibraryInlineRows.attach(to: target)
    }
}

enum OfflineLibraryHeaderEntry {
    private static let identifier = "EeveeOfflineLibraryHeaderEntry"
    private static let libraryClassFragment = "YourLibraryViewController"
    private static let buttonSize: CGFloat = 44

    static func attach(to header: UIView) {
        let existing = header.eeveeFirst(UIButton.self, where: { $0.accessibilityIdentifier == identifier })
        guard let search = header.eeveeFirst(UIView.self, where: {
            $0.accessibilityIdentifier == "YourLibraryHeader.search"
        }), let plus = header.eeveeFirst(UIView.self, where: {
            $0.accessibilityIdentifier == "YourLibraryHeader.plus"
        }), let title = header.eeveeFirst(UIView.self, where: {
            $0.accessibilityIdentifier == "YourLibraryHeader.title"
        }) else {
            existing?.isHidden = true
            return
        }

        let searchFrame = search.convert(search.bounds, to: header)
        let frame = CGRect(x: searchFrame.minX - buttonSize - 4,
                           y: searchFrame.midY - buttonSize / 2,
                           width: buttonSize, height: buttonSize)
        let controls = descendants(in: header).filter {
            $0 !== existing && !$0.isHidden && $0.alpha > 0.01 && $0.isUserInteractionEnabled &&
                ($0 is UIControl || $0.accessibilityIdentifier?.hasPrefix("YourLibraryHeader.") == true)
        }
        let overlapsControl = controls.contains {
            $0.convert($0.bounds, to: header).insetBy(dx: -2, dy: -2).intersects(frame)
        }
        let titleFrame = title.convert(title.bounds, to: header)
        let plusFrame = plus.convert(plus.bounds, to: header)
        guard header.bounds.contains(frame),
              !titleFrame.insetBy(dx: -2, dy: -2).intersects(frame),
              !plusFrame.insetBy(dx: -2, dy: -2).intersects(frame),
              !overlapsControl else {
            existing?.isHidden = true
            return
        }

        let button = existing ?? makeButton(for: header)
        if button.superview !== header { header.addSubview(button) }
        if button.frame != frame { button.frame = frame }
        button.isHidden = false
        if header.subviews.last !== button { header.bringSubviewToFront(button) }
    }

    private static func descendants(in root: UIView) -> [UIView] {
        var result: [UIView] = []
        var queue = root.subviews
        var index = 0
        while index < queue.count {
            let view = queue[index]
            index += 1
            result.append(view)
            queue += view.subviews
        }
        return result
    }

    private static func makeButton(for header: UIView) -> UIButton {
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = "offline_library_header_entry".localized
        button.accessibilityHint = "offline_library_header_entry_hint".localized
        button.tintColor = .white
        button.setImage(UIImage(systemName: "arrow.down.circle"), for: .normal)
        button.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 20, weight: .medium), forImageIn: .normal
        )
        button.addAction(UIAction { [weak header] _ in
            guard let header else { return }
            open(from: header)
        }, for: .primaryActionTriggered)
        return button
    }

    static func open(from source: UIView, initialURI: String? = nil) {
        guard let controller = WindowHelper.shared.viewController(for: source) else { return }
        var candidate: UIViewController? = controller
        while let current = candidate,
              !NSStringFromClass(type(of: current)).contains(libraryClassFragment) {
            candidate = current.parent
        }
        guard let library = candidate, let navigation = library.navigationController else {
            writeDebugLog("[Offline] My Library navigation controller unavailable")
            return
        }
        let title = "offline_library".localized
        guard navigation.topViewController?.title != title else { return }
        let page = EeveeSettingsViewController(
            library.view.bounds, settingsView: AnyView(OfflineLibraryView(initialURI: initialURI)), navigationTitle: title
        )
        navigation.pushViewController(page, animated: true)
    }
}

func activateOfflineLibraryHeaderEntry() {
    guard EeveeSpotify.spotifyVersion == "9.1.88",
          let cls = NSClassFromString(OfflineLibraryHeaderEntryHook.targetName),
          class_getInstanceMethod(cls, #selector(UIView.layoutSubviews)) != nil else {
        writeDebugLog("[Offline] My Library header entry skipped: version or class mismatch")
        return
    }
    OfflineLibraryHeaderEntryGroup().activate()
    writeDebugLog("[Offline] My Library header entry hook active")
}
