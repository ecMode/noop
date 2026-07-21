import Foundation
import AVFoundation

/// Spoken workout announcements — HR-zone changes and per-mile splits — during a live run. Uses the
/// system text-to-speech voice and, on iOS, ducks other audio (music / podcasts) so the cue is heard
/// and then restored. Deliberately independent of the WHOOP strap: audio needs no BLE bond, so it works
/// on an unbonded phone run (the haptic `buzz()` path, which DOES need the bond, is separate).
///
/// Audio-session contract (the part that used to break): `.duckOthers` lowers other audio only while OUR
/// session is active, so the session must be deactivated the moment the queue drains — otherwise music
/// stays ducked for the rest of the run. All session access is serialized on the main actor (the delegate
/// callbacks hop back on), deactivation RETRIES if the audio route is still busy (so a stuck-duck can't
/// persist), and both `didCancel` (interrupted utterance) and audio-session interruptions (a call / Siri /
/// route change) are handled — an unhandled cancel/interruption was what left the synth wedged and silent
/// after working at the start of a run.
///
/// Cross-platform-safe: `AVAudioSession` is iOS-only and guarded; on macOS the synthesizer just speaks.
@MainActor
final class WorkoutVoice: NSObject, AVSpeechSynthesizerDelegate {

    private let synth = AVSpeechSynthesizer()
    /// Our belief about whether the shared session is active + ducking. Kept honest across interruptions so
    /// `announce` always (re)activates when needed rather than speaking silently into a deactivated session.
    private var sessionActive = false
    /// The pending un-duck. Cancelled when a new cue arrives (don't un-duck then immediately re-duck) and
    /// re-armed with backoff while the route is still busy, so the session always returns to inactive.
    private var deactivateTask: Task<Void, Never>?

    override init() {
        super.init()
        synth.delegate = self
#if os(iOS)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
#endif
    }

    /// Speak a short line. Lines are brief and infrequent (a zone change or a mile marker), so if one is
    /// still speaking the next just queues behind it. Never load-bearing — a missed line is harmless.
    func announce(_ text: String) {
        // A fresh cue cancels any in-flight un-duck so we don't deactivate the session right as we speak.
        deactivateTask?.cancel()
        deactivateTask = nil
        activateSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        // Speak at 0.9 (of the device media volume) rather than full — a touch softer so the cue sits over
        // the ducked music without feeling like it's shouting over it. Independent of the `.duckOthers` dip.
        utterance.volume = 0.9
        synth.speak(utterance)
    }

    /// Stop any speech and guarantee the session is deactivated (music un-ducked). Called by `AppModel` when
    /// a workout ends so a wedged/interrupted session can never outlive the run with music left quiet.
    func endSession() {
        deactivateTask?.cancel()
        deactivateTask = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        forceDeactivate(attempt: 0)
    }

    // MARK: - Session lifecycle (iOS)

    private func activateSession() {
#if os(iOS)
        // `.playback` + `.duckOthers` lowers other audio for the cue (turn-by-turn-nav style) rather than
        // stopping it; `.mixWithOthers` keeps us polite; `.voicePrompt` mode is tuned for exactly this.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers])
            try session.setActive(true, options: [])
            sessionActive = true
        } catch {
            // If activation fails the cue may be silent, but that's harmless (never load-bearing). Leave
            // `sessionActive` false so the next cue tries again rather than assuming a good session.
            sessionActive = false
        }
#endif
    }

    /// Deactivate once the queue is fully drained. A short delay lets the speech audio route finish tearing
    /// down so `setActive(false)` doesn't throw `IsBusy`; on failure it re-arms with backoff (bounded) so a
    /// transiently-busy route can never leave music ducked for the rest of the run.
    private func scheduleDeactivate() {
#if os(iOS)
        guard sessionActive else { return }
        forceDeactivate(attempt: 0)
#endif
    }

    private func forceDeactivate(attempt: Int) {
#if os(iOS)
        deactivateTask?.cancel()
        deactivateTask = Task { @MainActor [weak self] in
            // Backoff: 0.15s, 0.3s, 0.45s … so the first (common) case un-ducks almost immediately.
            try? await Task.sleep(nanoseconds: UInt64(0.15 * 1_000_000_000) * UInt64(attempt + 1))
            guard let self, !Task.isCancelled else { return }
            // A new cue may have started while we waited; announce() cancels us, but double-check.
            guard !self.synth.isSpeaking else { return }
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
                self.sessionActive = false
            } catch {
                if attempt < 5 { self.forceDeactivate(attempt: attempt + 1) }
                // else: give up after ~5.4s of retries; the session will be re-toggled by the next cue or
                // endSession(), and iOS reclaims a truly-orphaned session when the app backgrounds.
            }
        }
#endif
    }

#if os(iOS)
    /// A call / Siri / route change interrupts our session. On `.began` iOS has already deactivated us, so
    /// drop our bookkeeping (next cue reactivates cleanly) and cancel any pending un-duck; without this the
    /// synth stayed "active" in our eyes and every later cue spoke silently into a dead session.
    @objc private nonisolated func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if type == .began {
                self.deactivateTask?.cancel()
                self.deactivateTask = nil
                self.sessionActive = false
            }
            // On `.ended` we intentionally do nothing: the next announce() reactivates. Reactivating here
            // would re-duck music with no cue to justify it.
        }
    }
#endif

    // MARK: - Synthesizer delegate (hops back to the main actor for all session work)

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, !self.synth.isSpeaking else { return }
            self.scheduleDeactivate()
        }
    }

    /// An interrupted / stopped utterance fires `didCancel`, NOT `didFinish`. Handling it is what stops a
    /// mid-run interruption from leaving the session active and the music ducked (the reported bug).
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, !self.synth.isSpeaking else { return }
            self.scheduleDeactivate()
        }
    }
}
