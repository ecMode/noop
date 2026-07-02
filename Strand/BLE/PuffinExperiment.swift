import Foundation

/// Opt-in switch for the EXPERIMENTAL WHOOP 5.0/MG ("puffin") protocol probes.
///
/// Live HR on a 5/MG strap already works over the standard profile after CLIENT_HELLO. These probes
/// go further — sending puffin-framed commands (e.g. asking the strap to start its realtime stream)
/// to learn what a real 5/MG strap responds to. They are guesses, so they are OFF by default and only
/// ever written to the puffin command characteristic (fd4b0002). A 5/MG owner can flip this on under
/// Settings → Experimental to help map the protocol; everyone else is unaffected.
enum PuffinExperiment {
    /// Shared with the Settings toggle via `@AppStorage(PuffinExperiment.defaultsKey)`.
    static let defaultsKey = "noopPuffinExperiments"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// Separate, more-deliberate opt-in for the WHOOP 5/MG "R22" deep-data unlock — the one probe
    /// that WRITES a persistent feature flag to the strap (the `enable_r22_*` SET_CONFIG sequence the
    /// official app sends; documented by judes.club + Asherlc/dofek). Kept distinct from the read-only
    /// probes above because it changes strap state, so it must be turned on explicitly and is still
    /// fully reversible. Driven only from `BLEManager.enableWhoop5DeepData()`. (#174)
    static let deepDataKey = "noopWhoop5DeepData"

    static var deepDataEnabled: Bool { UserDefaults.standard.bool(forKey: deepDataKey) }

    /// Opt-in "Broadcast heart rate": writes the device-config flag `whoop_live_hr_in_adv_ind_pkt="1"`
    /// so the strap advertises the standard Heart Rate Service (0x180D) + its live HR, pairable by a
    /// Garmin/Zwift/gym HR client. Reversible, default off; applied on each 5/MG connection and driven by
    /// `BLEManager.setBroadcastHr(_:)`. Mirrors the Android `PuffinExperiment.KEY_BROADCAST_HR`. (#181)
    static let broadcastHrKey = "noopBroadcastHr"

    static var broadcastHrEnabled: Bool { UserDefaults.standard.bool(forKey: broadcastHrKey) }

    /// Opt-in "Continuous HRV capture": hold the dense realtime HR stream armed even with no Live screen
    /// open, so the strap banks beat-to-beat R-R intervals 24/7 for far better overnight HRV/recovery/
    /// sleep (vs the sparse history offload). Uses more battery (continuous HR streaming). Default OFF;
    /// applied on launch + each (re)bond and driven by `BLEManager.setKeepRealtimeForData(_:)`. Mirrors
    /// the Android `NoopPrefs.KEY_CONTINUOUS_HRV`. Works on WHOOP 4 and 5/MG (both emit 0x2A37 R-R).
    static let keepRealtimeForDataKey = "noopContinuousHrv"

    static var keepRealtimeForDataEnabled: Bool { UserDefaults.standard.bool(forKey: keepRealtimeForDataKey) }

    /// Opt-in "Experimental sleep staging (V2)": re-stage each detected night with `SleepStagerV2` — a
    /// transparent cardiorespiratory recipe (reimplemented from contributor PR #600) that recovers deep/REM
    /// better than the shipped V1 stager on its author's n=1 validation. Pure analysis switch: it changes
    /// ONLY which staging engine runs over an already-detected sleep window; sleep DETECTION, scoring and the
    /// default V1 path are all untouched. Default OFF. Read at the staging call site (Repository) to pick
    /// V1 vs V2. Mirrors the Android `PuffinExperiment.KEY_EXPERIMENTAL_SLEEP_V2`.
    static let experimentalSleepV2Key = "noopExperimentalSleepV2"

    static var experimentalSleepV2Enabled: Bool { UserDefaults.standard.bool(forKey: experimentalSleepV2Key) }

    /// Whether to stage sleep with V2 for the CURRENT strap, folding in the per-model DEFAULT. V2 is now
    /// the DEFAULT on WHOOP 5/MG: that family carries NO raw respiration ADC, and V1 stages a no-resp
    /// night badly — with the resp channel absent its deep gate and REM path collapse, burying the night
    /// in "light" (measured: a real 5/MG night staged 4% deep / 87% light under V1 vs 33% / 28% under V2,
    /// the latter matching the wearer's habitual architecture). V2 recovers breathing regularity from the
    /// R-R stream via RSA, the signal V1 ignores. V1 stays the default on WHOOP 4.0 (which DOES carry the
    /// resp channel and which V1 was tuned against). The `experimentalSleepV2Enabled` toggle still FORCES
    /// V2 on any model — a manual override for a 4.0 owner who wants it. Mirror on Android
    /// (`PuffinExperiment.useSleepStagerV2`) for cross-platform parity.
    static var useSleepStagerV2: Bool {
        experimentalSleepV2Enabled || WhoopModel.persisted == .whoop5mg
    }

    /// Opt-in "Auto-detect workouts": after a sync / on Today appear, scan the last day or two of HR for a
    /// SUSTAINED-ELEVATED window (resting HR + 30 bpm held ≥ 12 min) that doesn't overlap a saved workout,
    /// and surface ONE dismissible Today card offering to save it as a manual-style workout. Pure read +
    /// suggestion: nothing is ever created without the user tapping Save, and turning this OFF stops all
    /// detection and hides the card. Default OFF. Mirrors the Android `NoopPrefs.KEY_AUTO_DETECT_WORKOUTS`.
    static let autoDetectWorkoutsKey = "noopAutoDetectWorkouts"

    static var autoDetectWorkoutsEnabled: Bool { UserDefaults.standard.bool(forKey: autoDetectWorkoutsKey) }
}
