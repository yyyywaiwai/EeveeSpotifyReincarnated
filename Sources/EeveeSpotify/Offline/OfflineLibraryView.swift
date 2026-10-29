import AVFoundation
import Combine
import SwiftUI

struct OfflineLibraryView: View {
    private static let ioQueue = DispatchQueue(label: "com.eeveespotify.offline-library", qos: .userInitiated)
    let initialURI: String?

    @State private var tracks: [OfflineSavedTrack] = []
    @State private var initialSelectionConsumed = false
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var pendingDeletion: OfflineSavedTrack?
    @State private var player: AVAudioPlayer?
    @State private var playingURI: String?
    @State private var isPlaying = false
    @State private var position: TimeInterval = 0
    @State private var duration: TimeInterval = 0

    init(initialURI: String? = nil) {
        self.initialURI = initialURI
    }

    var body: some View {
        List {
            Section(footer: Text("offline_library_footer".localized)) {
                if let errorMessage {
                    Text(errorMessage).foregroundColor(.red)
                }
                if isLoading {
                    ProgressView()
                } else if tracks.isEmpty && errorMessage == nil {
                    Text("offline_library_empty".localized).foregroundColor(.secondary)
                } else if !tracks.isEmpty {
                    ForEach(tracks, id: \.uri) { track in
                        Button { playOrPause(track) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: playingURI == track.uri && isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.title2)
                                VStack(alignment: .leading) {
                                    Text(track.title.isEmpty ? track.uri : track.title).lineLimit(1)
                                    Text(track.artist).font(.footnote).foregroundColor(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                    }
                    .onDelete { offsets in
                        guard let index = offsets.first, tracks.indices.contains(index) else { return }
                        pendingDeletion = tracks[index]
                    }
                }
            }

            if let playingURI, let track = tracks.first(where: { $0.uri == playingURI }) {
                Section(header: Text("offline_library_player".localized)) {
                    Text(track.title.isEmpty ? track.uri : track.title).font(.headline).lineLimit(1)
                    Slider(value: Binding(
                        get: { position },
                        set: { value in
                            player?.currentTime = value
                            position = value
                        }
                    ), in: 0...max(duration, 0.01))
                    .accessibilityLabel("offline_library_seek".localized)
                    HStack {
                        Text(SponsorBlockFormatters.shortTime(position))
                        Spacer()
                        Text(SponsorBlockFormatters.shortTime(duration))
                    }
                    .font(.footnote.monospacedDigit())
                    Button(isPlaying ? "offline_library_pause".localized : "offline_library_play".localized) {
                        playOrPause(track)
                    }
                }
            }
        }
        .eeveeSettingsStyle()
        .onAppear(perform: reload)
        .onDisappear {
            player?.stop()
            player = nil
            playingURI = nil
            isPlaying = false
        }
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            guard let player else { return }
            position = player.currentTime
            isPlaying = player.isPlaying
        }
        .alert(isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            Alert(
                title: Text("offline_library_delete".localized),
                message: Text("offline_library_delete_confirm".localized),
                primaryButton: .destructive(Text("offline_library_delete".localized)) {
                    guard let track = pendingDeletion else { return }
                    pendingDeletion = nil
                    if playingURI == track.uri {
                        player?.stop()
                        player = nil
                        playingURI = nil
                        isPlaying = false
                    }
                    Self.ioQueue.async {
                        let result = Result { try OfflineTrackStore.shared.remove(uri: track.uri) }
                        DispatchQueue.main.async {
                            switch result {
                            case .success: reload()
                            case .failure: errorMessage = "offline_library_delete_failed".localized
                            }
                        }
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func reload() {
        isLoading = true
        Self.ioQueue.async {
            let result = Result { try OfflineTrackStore.shared.tracks() }
            DispatchQueue.main.async {
                isLoading = false
                switch result {
                case .success(let entries):
                    tracks = entries.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
                    errorMessage = nil
                    if let initialURI, !initialSelectionConsumed,
                       let entry = tracks.first(where: { $0.uri == initialURI }) {
                        initialSelectionConsumed = true
                        playOrPause(entry)
                    }
                case .failure:
                    tracks = []
                    errorMessage = "offline_library_read_failed".localized
                }
            }
        }
    }

    private func playOrPause(_ track: OfflineSavedTrack) {
        if playingURI == track.uri, let player {
            if player.isPlaying {
                player.pause()
            } else {
                if player.currentTime >= player.duration { player.currentTime = 0 }
                _ = player.play()
            }
            isPlaying = player.isPlaying
            return
        }
        do {
            guard let url = try OfflineTrackStore.shared.fileURL(for: track.uri) else {
                errorMessage = "offline_library_missing".localized
                return
            }
            player?.stop()
            player = nil
            playingURI = nil
            isPlaying = false
            let next = try AVAudioPlayer(contentsOf: url)
            next.prepareToPlay()
            guard next.play() else { throw OfflineLibraryError.playbackFailed }
            player = next
            playingURI = track.uri
            duration = next.duration
            position = next.currentTime
            isPlaying = true
            errorMessage = nil
        } catch {
            errorMessage = "offline_library_play_failed".localized
        }
    }

}

private enum OfflineLibraryError: Error {
    case playbackFailed
}
