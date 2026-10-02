import Foundation

// MARK: - Mirror mode: the dev build reads the release build's data instead of its own
//
// The two installs have different bundle ids (`com.noopapp.noop` and `…​.staging`), so they have separate
// containers and separate databases. That isolation is the point — a dev build cannot corrupt real history —
// but it leaves two problems the user actually hit:
//
//   1. BATTERY. Both apps auto-reconnect to the same strap and both run the 900 s periodic offload, so they
//      fight over one BLE connection all day. Two radios' worth of work for one strap's data.
//   2. TWO DATABASES TO MAINTAIN. Logging a meal twice, weighing in twice, keeping a goal in step — it is
//      not sustainable, and a dev build with empty history cannot exercise the features that need weeks of it.
//
// Mirror mode answers both with one idea: the dev build stops being a second CLIENT and becomes a reader of
// the release build's backups. The release app already writes `.noopbak` snapshots to a folder the user picks
// (`FolderBackup`, auto-enabled); the dev build points at the same folder and restores the newest one on
// resume.
//
// SO IT DELIBERATELY DOES NOT TOUCH THE STRAP. Not "syncs less" — not at all. A mirror with its own BLE
// connection would still fight for the radio, and worse, would write strap data into a database that is
// about to be overwritten by the next restore. Doing nothing is both cheaper and more correct.
//
// RELEASE BUILDS CANNOT ENTER IT. `isEnabled` is compiled to a constant `false` outside `NOOP_DEV_BUILD`, so
// the real install can never stop talking to the strap because of a stray preference — including one that
// arrives through a restored `.noopbak`, which is exactly how this could otherwise leak across.
//
// The type exists on both configurations so call sites need no `#if`; only its answers change.
enum DebugMirror {

    private static let enabledKey = "noop.debugMirrorMode"
    /// The snapshot last restored, so a resume does not re-restore the same file repeatedly.
    private static let lastRestoredKey = "noop.debugMirrorLastSnapshot"

    /// Whether this install is mirroring a release build's data.
    ///
    /// Hard-false on release, by construction rather than by checking a flag at runtime — see the header.
    static var isEnabled: Bool {
        #if NOOP_DEV_BUILD
        return UserDefaults.standard.bool(forKey: enabledKey)
        #else
        return false
        #endif
    }

    /// Whether mirror mode can even be offered. Release builds hide the setting entirely rather than showing
    /// a switch that does nothing.
    static var isAvailable: Bool {
        #if NOOP_DEV_BUILD
        return true
        #else
        return false
        #endif
    }

    static func setEnabled(_ on: Bool) {
        #if NOOP_DEV_BUILD
        UserDefaults.standard.set(on, forKey: enabledKey)
        if on { enableMirroredFeatures() }
        // The marker is cleared on EVERY transition, in both directions. Turning mirror mode off and back on
        // should re-read the folder rather than trust a marker describing a database that has since been
        // written to by a strap — the one case where the marker would be a lie.
        UserDefaults.standard.removeObject(forKey: lastRestoredKey)
        #endif
    }

    /// Turn on the feature toggles the mirrored data needs in order to be visible.
    ///
    /// THE BUG THIS FIXES. `.noopbak` carries the DATABASE plus a whitelist of scalar settings, and that
    /// whitelist deliberately excludes every `noop.*` feature toggle as device-specific. Correct for a real
    /// restore — but it means a mirror gets prod's food entries, weigh-ins and diet goal while
    /// `noop.foodLogging` stays off, so the diet card, the Diet screen and the Calories diet branch are all
    /// hidden and the data looks absent rather than merely un-surfaced.
    ///
    /// Written rather than intercepted at the read: the flag is bound through `@AppStorage` in a dozen
    /// views, and a mirror-aware read would have to be added to each — twelve places to miss one.
    ///
    /// Left ON when mirror mode is switched off, deliberately. It is a feature toggle the user can flip
    /// back in Settings, and silently turning off a feature they may have been using is worse than leaving
    /// an extra one on.
    private static func enableMirroredFeatures() {
        UserDefaults.standard.set(true, forKey: FoodLogStore.enabledKey)
    }

    /// True when the app must not open or hold a strap connection.
    ///
    /// Named for what it MEANS rather than as a bare `isEnabled` read, so the BLE gates gain a line that says
    /// why they are refusing instead of a flag a later reader has to go and look up.
    static var suppressesStrapWork: Bool { isEnabled }

    static var lastRestoredSnapshot: String? {
        UserDefaults.standard.string(forKey: lastRestoredKey)
    }

    /// Record a restore, so the next resume knows there is nothing new to do.
    static func noteRestored(_ name: String) {
        UserDefaults.standard.set(name, forKey: lastRestoredKey)
    }

    /// The newest snapshot worth restoring, or nil when there is nothing new.
    ///
    /// Compares by NAME rather than by timestamp, deliberately: `FolderBackup`'s names are a sortable stamp
    /// (`snapshotTimeMs` parses them), and the name is the thing the restore is keyed on. Comparing parsed
    /// times while restoring by name would let the two disagree if a file were ever renamed.
    ///
    /// Pure, so the decision is testable without a folder or a database.
    static func snapshotToRestore(available: [String], lastRestored: String?) -> String? {
        guard let newest = BackupSync.latestSnapshot(available) else { return nil }
        guard let lastRestored else { return newest }
        // Equal means already done. Older than the marker means the folder has gone BACKWARDS — a snapshot
        // deleted, or a different folder picked — and restoring an older state over a newer one silently
        // loses data, so it is refused rather than treated as an update.
        guard let newestMs = BackupSync.snapshotTimeMs(newest),
              let lastMs = BackupSync.snapshotTimeMs(lastRestored) else {
            return newest == lastRestored ? nil : newest
        }
        return newestMs > lastMs ? newest : nil
    }
}

// MARK: - The resume-time restore

extension DebugMirror {

    /// Outcome of a mirror refresh, so the caller can log it honestly rather than guessing.
    enum RefreshOutcome: Equatable {
        /// Restored, and the app must reload everything it holds in memory.
        case restored(snapshot: String)
        /// Nothing newer in the folder. The overwhelmingly common answer on a resume.
        case upToDate
        /// Mirror mode is off, or this is a release build.
        case notMirroring
        /// No folder configured yet — the user has not pointed this install at the release build's folder.
        case noFolder
        case failed(String)
    }

    /// Restore the release build's newest snapshot, if there is a newer one than last time.
    ///
    /// CALLED AT LAUNCH, before the database is opened, and that timing is the whole trick. A restore
    /// replaces the SQLite file wholesale, so `DataBackup.restore` reports that "a relaunch is required for
    /// it to take effect" — GRDB's open connection would still be pointing at the replaced inode. Doing it
    /// before anything opens the store means there is no connection to invalidate and no relaunch to ask
    /// for: the app simply opens the fresh file.
    ///
    /// Synchronous for the same reason. It has to finish before `AppModel` exists, and both halves
    /// (`listSnapshots`, `restore`) are already synchronous file work — making this async would mean a
    /// window where the old database is open and a restore is in flight.
    ///
    /// Not on a timer and not on resume. The release app writes a snapshot on its own schedule; a dev build
    /// that polled would burn the battery this mode exists to save.
    ///
    /// Returns without restoring when nothing is newer, which is the normal case and costs one directory
    /// listing.
    @discardableResult
    static func refreshFromProd() -> RefreshOutcome {
        guard isEnabled else { return .notMirroring }
        guard FolderBackup.hasFolder else { return .noFolder }

        let available = FolderBackup.listSnapshots().map(\.name)
        guard let target = snapshotToRestore(available: available, lastRestored: lastRestoredSnapshot) else {
            return .upToDate
        }

        // Goes through `FolderBackup.restore`, so every hardened safety still applies — magic-byte and
        // GRDB-origin validation, the sidecar snapshot, and the rollback. A mirror is not a reason to take
        // a shortcut through a file this app did not write.
        switch FolderBackup.restore(snapshotNamed: target) {
        case .imported:
            noteRestored(target)
            // Also here, not only on the toggle: a restore can bring food data to an install whose flag was
            // never set — a mirror enabled before prod had any diet history, say.
            enableMirroredFeatures()
            return .restored(snapshot: target)
        case .failure(let message):
            // The marker is deliberately NOT advanced on a failure, so the next launch tries again rather
            // than recording a broken restore as done.
            return .failed(message)
        case .restoreTooLarge(_, let limit):
            // The decompression guard. Mirror mode does NOT override it: the ceiling exists to stop a
            // hostile archive, and "this file came from my own other install" is an assumption, not a
            // verification. The user can still restore it by hand, where the override is a deliberate tap.
            return .failed("That snapshot is larger than the \(limit)-byte restore ceiling.")
        case .cancelled, .exported, .exportedOversize:
            // Export outcomes cannot arise from a restore call; treated as a no-op rather than asserted,
            // because a launch path is the wrong place to trap on an impossible case.
            return .upToDate
        }
    }
}
