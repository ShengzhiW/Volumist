import MediaPlayer

/// Makes Volumist the Mac's Now Playing app for a moment.
///
/// macOS's Smart Routing scores a request to take AirPods back from an iPhone by the app that
/// asks. All Mac audio reaches the AirPods through Volumist, which counts as an ordinary app and
/// loses to an iPhone that's playing media. Media apps (the Now Playing one) score higher, so
/// Volumist claims Now Playing while it takes the AirPods, and lets go right after.
@MainActor
final class NowPlayingClaim {
    private var targets: [(MPRemoteCommand, Any)] = []
    private(set) var isActive = false

    func begin(title: String) {
        guard !isActive else { return }
        isActive = true
        // macOS only treats an app as Now Playing if it handles playback commands. These do
        // nothing: the claim lasts about a second.
        let center = MPRemoteCommandCenter.shared()
        targets = [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand].map { command in
            (command, command.addTarget { _ in .success })
        }
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        info.playbackState = .playing
    }

    func end() {
        guard isActive else { return }
        isActive = false
        for (command, target) in targets { command.removeTarget(target) }
        targets = []
        let info = MPNowPlayingInfoCenter.default()
        info.playbackState = .stopped
        info.nowPlayingInfo = nil
    }
}
