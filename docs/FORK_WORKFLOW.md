# Fork workflow (ecMode / Loop)

How this fork stays current with upstream while carrying its own identity and features.

## Remotes

| remote | points at | role |
|--------|-----------|------|
| `origin` | `ecMode/noop` | this fork (push here) |
| `upstream` | `NoopApp/noop` | the source project (pull from here, never push) |

## Branch model

```
upstream/main ──fetch──▶ main             pristine mirror of upstream. NEVER commit your own
                            │ merge         work here — it exists only to receive upstream and
                            ▼               hand it to loop-main with a clean history.
                         loop-main         THE fork line. Carries the "fork identity" config +
                            │               every shipped feature. Build & release from here.
             ┌──────────────┼──────────────┐
        feature/x       feature/y      feature/z    branch off loop-main, one concern each,
                                                     merge back into loop-main.
```

- **`main`** — a read-only mirror of `upstream/main`. Only ever fast-forwarded to upstream. If `git merge --ff-only upstream/main` ever fails, someone committed to `main` by mistake; move that commit to `loop-main` and reset `main` back to the mirror.
- **`loop-main`** — the permanent integration/shipping branch (the fork's own "main"; named for the app, `com.ecmode.loop` / "Loop"). Holds the ecMode build config (bundle id `com.ecmode.loop`, app name "Loop", CloudKit container, signing team) plus all merged features. This is what gets built and sideloaded.
- **feature branches** — branch off `loop-main`, do one thing, merge back (rebase while private, merge once pushed). The existing `zone-haptic-coaching → workout-audio-alerts → strava-upload → cloudkit-sync` stack are feature branches; they land on `loop-main`.

## Pull upstream (the routine)

```sh
git fetch upstream
git checkout main
git merge --ff-only upstream/main     # main stays a pure mirror; fails loudly if it was dirtied
git checkout loop-main
git merge main                        # bring upstream into the fork line
# resolve conflicts (see below), build, then rebase in-flight feature branches onto loop-main
```

Push `loop-main` (and, if you mirror it, `main`) to `origin`. **Pushing requires the ecMode GitHub
account** — see the `git-accounts-noop` / `push-then-restore-eric-ba` memories: `gh auth switch
--user ecMode` before pushing, then switch back to `eric-ba` immediately after. Never leave
ecMode active.

## Expected merge conflicts

Every upstream sync will conflict in the **fork-identity / build-config** files, because both
sides edit them:

- `project.yml`
- `Strand/Resources/Info.plist`, `StrandiOS/Resources/Info.plist`
- `Strand/Resources/Strand.entitlements`, `StrandiOS/Resources/NOOP.entitlements`
- `altstore-source.json`
- `Packages/StrandDesign/Sources/StrandDesign/WatchScoreSnapshot.swift` (app-group id)

**Resolution rule:** keep the ecMode values (`com.ecmode.loop`, "Loop", team `QX8VRKT84F`,
`iCloud.com.ecmode.loop`, deployment target 14.0) while taking upstream's other changes to the
same file. The fork-identity commit is
`chore(fork): ecMode personal build config (com.ecmode.loop, ...)` — use it as the reference for
what the ecMode values should be.

> **Known wart:** fork identity is *entangled* with the CloudKit feature in `project.yml` and the
> Info.plists (the bundle-id change was forced by CloudKit needing real provisioning), so it
> could not be isolated into a single fork-identity-only commit. To shrink the recurring conflict
> surface later, move `PRODUCT_BUNDLE_IDENTIFIER` / team / container id into an `.xcconfig` that
> upstream doesn't touch, and reference it from `project.yml`.

## Do NOT delete `android/` or `NOOPWatch*` to "reduce scope"

Deleting a directory upstream still maintains causes a **modify/delete conflict on every sync**
for each file upstream changes there, and newly-added upstream files silently reappear. That is
strictly more work than leaving them. This fork ignores Android and Apple-Watch surfaces by
*attention*, not deletion (see the `ignore-android-and-watch` memory). If you truly want them out
of your working tree, use `git sparse-checkout` (keeps them for merges, just not checked out) —
never `git rm`.

## Out of scope for this fork

Work only the Apple phone/Mac app: `Strand/`, `StrandiOS/`, `StrandiOSShared/`, `Packages/*`.
Ignore `android/` and `NOOPWatch/` / `NOOPWatchComplications/`; don't make cross-platform parity
changes to the Kotlin twin.
