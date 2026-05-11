// mac/Howl/UI/Settings/Pipeline/WAVPlayer.swift
import Foundation
import Observation
import AVFoundation

/// In-app WAV playback for the Pipeline Inspector. One source plays at
/// a time — calling play(url:) with a different URL stops the prior
/// source and switches.
///
/// SwiftUI views observe currentURL / isPlaying / currentTime / duration
/// to drive a transport bar + per-row play/pause indicators. A timer
/// updates currentTime ~10 Hz so the scrubber tracks playback live.
@Observable
final class WAVPlayer: NSObject, AVAudioPlayerDelegate {
    /// URL currently loaded (playing or paused). nil when nothing is
    /// loaded — the transport bar hides itself in that state.
    private(set) var currentURL: URL? = nil
    private(set) var isPlaying: Bool = false
    private(set) var duration: TimeInterval = 0
    private(set) var currentTime: TimeInterval = 0
    /// User-facing error message when playback fails to start (e.g. the
    /// WAV header was never patched because the recorder didn't Close()).
    /// Cleared on the next successful play.
    private(set) var lastError: String? = nil

    private var player: AVAudioPlayer?
    private var tickTimer: Timer?

    /// Load + start playing. If the same URL is already loaded, resume
    /// from currentTime; otherwise stop the prior source and start fresh.
    func play(url: URL) {
        if currentURL == url, let p = player {
            p.play()
            isPlaying = true
            startTicking()
            return
        }
        stop()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            p.play()
            self.player = p
            self.currentURL = url
            self.duration = p.duration
            self.currentTime = 0
            self.isPlaying = true
            self.lastError = nil
            startTicking()
        } catch {
            self.lastError = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicking()
    }

    /// Convenience for row buttons: if the URL is already current, toggle
    /// pause/play; otherwise switch to it and play.
    func toggle(url: URL) {
        if currentURL == url, isPlaying {
            pause()
        } else {
            play(url: url)
        }
    }

    func seek(to time: TimeInterval) {
        guard let p = player else { return }
        p.currentTime = max(0, min(time, p.duration))
        currentTime = p.currentTime
    }

    /// Fully unload the source. Called when switching sources or when
    /// the playing source finishes.
    func stop() {
        player?.stop()
        player = nil
        currentURL = nil
        isPlaying = false
        duration = 0
        currentTime = 0
        stopTicking()
    }

    // MARK: - Tick timer (live scrubber)

    private func startTicking() {
        stopTicking()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let p = self.player else { return }
            self.currentTime = p.currentTime
        }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Land on the end of the track so the scrubber reflects the
        // final position, then mark stopped (keep currentURL so the row
        // stays "selected" visually for one more user click).
        currentTime = duration
        isPlaying = false
        stopTicking()
    }
}
