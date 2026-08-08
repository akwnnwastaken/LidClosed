import Foundation

/// Ensures only one LidClosed instance manages the sleep override at a time.
///
/// Two instances are genuinely harmful: the second one sees the first one's *live* state
/// file, concludes the override is stale, and tries to undo it — presenting an unexplained
/// authentication dialog and silently re-enabling sleep.
///
/// A `flock` is used rather than a bundle-identifier check because it also catches the raw
/// executable being run outside an app bundle, which is the common case while developing and
/// is exactly how this bug was originally found. The kernel releases the lock when the
/// process dies, including on SIGKILL, so a crash never leaves a stale lock behind.
final class InstanceLock {

    private let lockFileURL: URL

    /// Kept open for the lifetime of the process: closing it would release the lock.
    private var fileDescriptor: Int32 = -1

    init(lockFileURL: URL = InstanceLock.defaultLockFileURL()) {
        self.lockFileURL = lockFileURL
    }

    static func defaultLockFileURL() -> URL {
        PowerManager.defaultStateFileURL()
            .deletingLastPathComponent()
            .appendingPathComponent("instance.lock")
    }

    /// Attempts to take the lock.
    ///
    /// - Returns: `true` if this process may proceed, `false` if another instance holds the
    ///   lock. If the lock file cannot be opened at all this returns `true` — a missing lock
    ///   is a lost safeguard, but refusing to launch over it would be worse.
    func tryAcquire() -> Bool {
        try? FileManager.default.createDirectory(
            at: lockFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let descriptor = open(lockFileURL.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor != -1 else {
            NSLog("[LidClosed] Could not open lock file (errno \(errno)) — continuing unlocked")
            return true
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }

        fileDescriptor = descriptor
        return true
    }
}
