import Foundation
import AVFoundation

/// Spoken workout announcements — HR-zone changes and per-mile splits — during a live run. Uses the
/// system text-to-speech voice and, on iOS, ducks other audio (music / podcasts) so the cue is heard
/// and then restored. Deliberately independent of the WHOOP strap: audio needs no BLE bond, so it works
/// on an unbonded phone run (the haptic `buzz()` path, which DOES need the bond, is separate).
///
/// Cross-platform-safe: `AVAudioSession` is iOS-only and guarded; on macOS the synthesizer just speaks.
@MainActor
final class WorkoutVoice: NSObject, AVSpeechSynthesizerDelegate {

    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Speak a short line. Lines are brief and infrequent (a zone change or a mile marker), so if one is
    /// still speaking the next just queues behind it. Never load-bearing — a missed line is harmless.
    func announce(_ text: String) {
#if os(iOS)
        // `.playback` + `.duckOthers` lowers other audio for the cue (turn-by-turn-nav style) rather than
        // stopping it; `.mixWithOthers` keeps us polite. Restored in `didFinish` once the queue drains.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true, options: [])
#endif
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.speak(utterance)
    }

    // Restore other audio to full volume once nothing more is queued (un-duck). If another line is still
    // in flight we leave the session active so we don't yo-yo the music volume between back-to-back lines.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
#if os(iOS)
        guard !synthesizer.isSpeaking else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
#endif
    }
}
