import Foundation

/// "Artist — Song" (or just the song) for media players that publish it.
///
/// The system-wide now-playing API (MediaRemote) is private and no longer answers
/// third-party apps, so this covers the players that broadcast their state: Music,
/// Spotify and TV post a distributed notification on every change, and a one-time
/// AppleScript query (with a short timeout, never launching the app) fills in the
/// track that was already playing when Volumist started.
@MainActor
final class NowPlayingMonitor {
    private struct Player {
        let bundleID: String
        let notification: String
    }

    private static let players = [
        Player(bundleID: "com.apple.Music", notification: "com.apple.Music.playerInfo"),
        Player(bundleID: "com.spotify.client", notification: "com.spotify.client.PlaybackStateChanged"),
        Player(bundleID: "com.apple.TV", notification: "com.apple.TV.playerInfo"),
    ]

    /// Display text per bundle ID.
    private(set) var titles: [String: String] = [:]
    var onChange: (() -> Void)?

    private var primed: Set<String> = []
    private var observers: [NSObjectProtocol] = []
    private let scriptQueue = DispatchQueue(label: "app.volumist.now-playing")

    init() {
        let center = DistributedNotificationCenter.default()
        for player in Self.players {
            let bundleID = player.bundleID
            observers.append(center.addObserver(forName: .init(player.notification), object: nil, queue: .main) { [weak self] note in
                let state = note.userInfo?["Player State"] as? String
                let name = note.userInfo?["Name"] as? String
                let artist = note.userInfo?["Artist"] as? String
                MainActor.assumeIsolated {
                    self?.primed.insert(bundleID)
                    if state == "Stopped" {
                        self?.set(nil, artist: nil, for: bundleID)
                    } else {
                        self?.set(name, artist: artist, for: bundleID)
                    }
                }
            })
        }
    }

    /// Call with the bundle IDs of the apps currently listed; fetches titles for new ones.
    func track(running bundleIDs: Set<String>) {
        // Forget players that quit so a relaunch is queried again.
        for id in primed where !bundleIDs.contains(id) {
            primed.remove(id)
            set(nil, artist: nil, for: id)
        }
        for player in Self.players where bundleIDs.contains(player.bundleID) && !primed.contains(player.bundleID) {
            primed.insert(player.bundleID)
            query(player.bundleID)
        }
    }

    private func query(_ bundleID: String) {
        let source = """
        if application id "\(bundleID)" is running then
            with timeout of 3 seconds
                tell application id "\(bundleID)"
                    if player state is not stopped then
                        set songName to name of current track
                        set artistName to ""
                        try
                            set artistName to artist of current track
                        end try
                        return artistName & tab & songName
                    end if
                end tell
            end timeout
        end if
        return ""
        """
        scriptQueue.async { [weak self] in
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.titles[bundleID] == nil, let result else { return }
                    let parts = result.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    if parts.count == 2 {
                        self.set(parts[1], artist: parts[0], for: bundleID)
                    } else {
                        self.set(result, artist: nil, for: bundleID)
                    }
                }
            }
        }
    }

    private func set(_ title: String?, artist: String?, for bundleID: String) {
        let song = Self.clean(title)
        let value = song.map { song in Self.clean(artist).map { "\($0) — \(song)" } ?? song }
        guard titles[bundleID] != value else { return }
        titles[bundleID] = value
        onChange?()
    }

    private static func clean(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
