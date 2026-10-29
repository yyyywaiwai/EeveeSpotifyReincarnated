import Foundation
import ObjectiveC.runtime
import UIKit

/// Eevee's own rows live in the native My Library scroll surface; Spotify's
/// section model and collection data source keep their original item counts.
enum OfflineLibraryInlineRows {
    private static var headerStateKey: UInt8 = 0
    private static var collectionStateKey: UInt8 = 0
    private static var retryKey: UInt8 = 0
    private static let rowHeight: CGFloat = 56
    private static let headingHeight: CGFloat = 36
    private static let maxInlineRows = 100
    private static let ioQueue = DispatchQueue(label: "com.eeveespotify.offline-inline-library", qos: .userInitiated)

    static func attach(to header: UIView) {
        guard Thread.isMainThread, header.window != nil else { return }
        guard let controller = WindowHelper.shared.viewController(for: header) else {
            retryOnce(header)
            return
        }
        var owner: UIViewController? = controller
        while let current = owner,
              !NSStringFromClass(type(of: current)).contains("YourLibraryViewController") {
            owner = current.parent
        }
        guard let root = owner?.viewIfLoaded, header.isDescendant(of: root) else {
            retryOnce(header)
            return
        }

        if let state = objc_getAssociatedObject(header, &headerStateKey) as? State,
           let collection = state.collection, collection.window != nil,
           collection.isDescendant(of: root),
           (objc_getAssociatedObject(collection, &collectionStateKey) as? State) === state {
            state.layout()
            return
        }

        let matches = descendants(in: root).compactMap { $0 as? UICollectionView }.filter {
            guard let source = $0.dataSource else { return false }
            return NSStringFromClass(type(of: $0)).contains("YourLibraryCollectionView") &&
                NSStringFromClass(type(of: source)).contains("YourLibraryContentViewBinder") &&
                NSStringFromClass(type(of: $0.collectionViewLayout)).contains("YourLibraryCompositionalLayout") &&
                $0.window != nil && !$0.isHidden
        }
        guard matches.count == 1, let collection = matches.first,
              collection.superview?.superview === header.superview,
              collection.bounds.width == header.bounds.width,
              collection.contentInset.top.isFinite,
              collection.adjustedContentInset.top.isFinite else {
            retryOnce(header)
            return
        }
        if let state = objc_getAssociatedObject(collection, &collectionStateKey) as? State {
            objc_setAssociatedObject(header, &headerStateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            state.layout()
        } else {
            let state = State(collection: collection)
            // The collection, not the replaceable header, owns its inset. Keeping
            // the state here prevents an old header's teardown from resetting a
            // newer header's identical inset after an asynchronous main turn.
            objc_setAssociatedObject(collection, &collectionStateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            objc_setAssociatedObject(header, &headerStateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            state.reload()
        }
    }

    private static func retryOnce(_ header: UIView) {
        guard objc_getAssociatedObject(header, &retryKey) == nil else { return }
        objc_setAssociatedObject(header, &retryKey, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        DispatchQueue.main.async { [weak header] in
            guard let header else { return }
            attach(to: header)
        }
    }

    private static func descendants(in root: UIView) -> [UIView] {
        var result: [UIView] = []
        var queue = root.subviews
        var index = 0
        while index < queue.count && result.count < 1_500 {
            let view = queue[index]
            index += 1
            result.append(view)
            queue += view.subviews
        }
        return result
    }

    private final class State {
        weak var collection: UICollectionView?
        private let section = UIView()
        private let baseInsetTop: CGFloat
        private let baseIndicatorTop: CGFloat
        private var appliedHeight: CGFloat = 0
        private var tracks: [OfflineSavedTrack] = []
        private var generation = 0
        private var isApplying = false
        private var isDisabled = false
        private var observer: NSObjectProtocol?

        init(collection: UICollectionView) {
            self.collection = collection
            baseInsetTop = collection.contentInset.top
            baseIndicatorTop = collection.verticalScrollIndicatorInsets.top
            section.accessibilityIdentifier = "EeveeOfflineSavedSection"
            section.backgroundColor = .black
            observer = NotificationCenter.default.addObserver(
                forName: OfflineTrackStore.changedNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.reload() }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func reload() {
            guard Thread.isMainThread else { DispatchQueue.main.async { self.reload() }; return }
            guard !isDisabled else { return }
            generation &+= 1
            let request = generation
            OfflineLibraryInlineRows.ioQueue.async { [weak self] in
                let latest = (try? OfflineTrackStore.shared.tracks()) ?? []
                DispatchQueue.main.async {
                    guard let self, self.generation == request else { return }
                    self.tracks = latest
                    self.render()
                }
            }
        }

        private func render() {
            section.subviews.forEach { $0.removeFromSuperview() }
            guard let collection, !tracks.isEmpty else { layout(); return }
            let width = collection.bounds.width
            // Establish the parent width before adding flexible-width rows.
            // UIKit otherwise expands a 375pt row to 750pt when a zero-width
            // section receives its first 375pt frame.
            section.frame.size.width = width
            let heading = UILabel(frame: CGRect(x: 16, y: 0, width: max(0, width - 32), height: OfflineLibraryInlineRows.headingHeight))
            heading.text = "offline_library".localized + " (\(tracks.count))"
            heading.textColor = .white
            heading.font = .systemFont(ofSize: 17, weight: .bold)
            heading.autoresizingMask = [.flexibleWidth]
            section.addSubview(heading)
            for (index, track) in tracks.prefix(OfflineLibraryInlineRows.maxInlineRows).enumerated() {
                section.addSubview(makeRow(track, index: index, width: width))
            }
            if tracks.count > OfflineLibraryInlineRows.maxInlineRows {
                section.addSubview(makeMoreRow(width: width))
            }
            layout()
        }

        private func makeMoreRow(width: CGFloat) -> UIButton {
            let row = UIButton(type: .system)
            row.frame = CGRect(x: 0,
                               y: OfflineLibraryInlineRows.headingHeight + CGFloat(OfflineLibraryInlineRows.maxInlineRows) * OfflineLibraryInlineRows.rowHeight,
                               width: width, height: OfflineLibraryInlineRows.rowHeight)
            row.autoresizingMask = [.flexibleWidth]
            row.accessibilityIdentifier = "EeveeOfflineSavedMore"
            let label = "offline_library_show_all".localized + " (\(tracks.count))"
            row.setTitle(label, for: .normal)
            row.accessibilityLabel = label
            row.isAccessibilityElement = true
            row.accessibilityTraits = .button
            row.tintColor = .systemGreen
            row.backgroundColor = .black
            row.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
            row.addAction(UIAction { [weak self] _ in
                guard let collection = self?.collection else { return }
                OfflineLibraryHeaderEntry.open(from: collection)
            }, for: .primaryActionTriggered)
            return row
        }

        private func makeRow(_ track: OfflineSavedTrack, index: Int, width: CGFloat) -> UIButton {
            let row = UIButton(type: .custom)
            row.frame = CGRect(x: 0, y: OfflineLibraryInlineRows.headingHeight + CGFloat(index) * OfflineLibraryInlineRows.rowHeight,
                               width: width, height: OfflineLibraryInlineRows.rowHeight)
            row.autoresizingMask = [.flexibleWidth]
            row.accessibilityIdentifier = "EeveeOfflineSavedRow.\(index)"
            row.accessibilityLabel = "\(track.title), \(track.artist)"
            row.accessibilityHint = "offline_library_row_hint".localized
            row.isAccessibilityElement = true
            row.accessibilityTraits = .button
            row.backgroundColor = .black

            let icon = UIImageView(image: UIImage(systemName: "arrow.down.circle.fill"))
            icon.frame = CGRect(x: 16, y: 16, width: 24, height: 24)
            icon.tintColor = .systemGreen
            icon.isUserInteractionEnabled = false
            icon.isAccessibilityElement = false
            row.addSubview(icon)

            let title = UILabel(frame: CGRect(x: 52, y: 7, width: max(0, width - 68), height: 23))
            title.text = track.title
            title.textColor = .white
            title.font = .systemFont(ofSize: 16, weight: .medium)
            title.lineBreakMode = .byTruncatingTail
            title.autoresizingMask = [.flexibleWidth]
            title.isAccessibilityElement = false
            row.addSubview(title)

            let artist = UILabel(frame: CGRect(x: 52, y: 30, width: max(0, width - 68), height: 18))
            artist.text = track.artist
            artist.textColor = .lightGray
            artist.font = .systemFont(ofSize: 12)
            artist.lineBreakMode = .byTruncatingTail
            artist.autoresizingMask = [.flexibleWidth]
            artist.isAccessibilityElement = false
            row.addSubview(artist)

            let separator = UIView(frame: CGRect(x: 52, y: OfflineLibraryInlineRows.rowHeight - 0.5,
                                                 width: max(0, width - 52), height: 0.5))
            separator.backgroundColor = UIColor.white.withAlphaComponent(0.16)
            separator.autoresizingMask = [.flexibleWidth]
            separator.isAccessibilityElement = false
            row.addSubview(separator)
            row.addAction(UIAction { [weak self] _ in self?.open(track.uri) }, for: .primaryActionTriggered)
            return row
        }

        func layout() {
            guard Thread.isMainThread, let collection, !isApplying, !isDisabled else { return }
            isApplying = true
            defer { isApplying = false }
            // Inline rows are bounded; the full validated store remains reachable
            // through the final "show all" row and the existing header button.
            let visibleCount = min(tracks.count, OfflineLibraryInlineRows.maxInlineRows)
            let rowCount = visibleCount + (tracks.count > OfflineLibraryInlineRows.maxInlineRows ? 1 : 0)
            let height = tracks.isEmpty ? 0 : OfflineLibraryInlineRows.headingHeight + CGFloat(rowCount) * OfflineLibraryInlineRows.rowHeight
            guard height.isFinite, collection.bounds.width > 0 else { return }
            let currentTop = collection.contentInset.top
            guard abs(currentTop - (baseInsetTop + appliedHeight)) < 0.5 ||
                  abs(currentTop - baseInsetTop) < 0.5 else {
                // Spotify assigned an unknown native inset. The value may be a
                // reset or an additive adjustment; subtracting our delta could
                // corrupt either case. Leave Spotify's value and offset intact.
                section.removeFromSuperview()
                isDisabled = true
                writeDebugLog("[Offline] My Library native inset changed; inline rows detached")
                return
            }
            if height > 0 {
                if section.superview !== collection { collection.addSubview(section) }
                section.frame = CGRect(x: 0, y: -height, width: collection.bounds.width, height: height)
            }
            let atTop = collection.contentOffset.y <= -collection.adjustedContentInset.top + 1
            if abs(currentTop - (baseInsetTop + height)) >= 0.5 {
                var inset = collection.contentInset
                inset.top = baseInsetTop + height
                collection.contentInset = inset
            }
            var indicators = collection.verticalScrollIndicatorInsets
            if abs(indicators.top - (baseIndicatorTop + height)) >= 0.5 {
                indicators.top = baseIndicatorTop + height
                collection.verticalScrollIndicatorInsets = indicators
            }
            if atTop {
                collection.setContentOffset(CGPoint(x: collection.contentOffset.x,
                                                   y: -collection.adjustedContentInset.top), animated: false)
            }
            appliedHeight = height
            section.isHidden = height == 0
            if height == 0 { section.removeFromSuperview() }
        }

        private func open(_ uri: String) {
            guard let collection else { return }
            OfflineLibraryInlineRows.ioQueue.async { [weak self, weak collection] in
                let valid = (try? OfflineTrackStore.shared.fileURL(for: uri)) != nil
                DispatchQueue.main.async {
                    guard let self, let collection, self.collection === collection else { return }
                    if valid { OfflineLibraryHeaderEntry.open(from: collection, initialURI: uri) }
                    else { self.reload() }
                }
            }
        }
    }
}
