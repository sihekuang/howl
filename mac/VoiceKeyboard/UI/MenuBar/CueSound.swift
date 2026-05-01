import AVFoundation
import os

/// Tiny audible feedback player. Fires a short listening-on cue when
/// recording starts so the user gets confirmation without staring at
/// the menu bar.
///
/// Volume is dialled down by default (0.3) so the cue is present but
/// not disruptive. The AVAudioPlayer instance is held as a property
/// so the sound has time to actually play before deinit; without that
/// the player gets released between hotkey-press and the audio thread
/// ever running and you hear nothing.
@MainActor
final class CueSound {
    private let log = Logger(subsystem: "com.voicekeyboard.app", category: "CueSound")
    private var player: AVAudioPlayer?

    /// Lazy load + cache the player. The MP3 lives in the bundle
    /// (project.yml sources include the whole VoiceKeyboard directory,
    /// so xcodebuild copies it into Contents/Resources).
    private func loadPlayer() -> AVAudioPlayer? {
        if let p = player { return p }
        guard let url = Bundle.main.url(forResource: "listen-cue", withExtension: "mp3") else {
            log.error("listen-cue.mp3 not found in bundle")
            return nil
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.volume = 0.3                   // subtle, non-disruptive
            p.prepareToPlay()
            player = p
            return p
        } catch {
            log.error("failed to init AVAudioPlayer: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Play the cue. No-op (with a logged error) if the asset is missing.
    /// Safe to call from rapid hotkey presses — the player rewinds and
    /// replays from the start.
    func playListening() {
        guard let p = loadPlayer() else { return }
        p.currentTime = 0
        p.play()
    }
}
