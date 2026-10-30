import AppKit
import Foundation
import os

/// One bridge per Mac.
///
/// The runtime binds three fixed addresses (60927 LAN, 60928 Codex hook, 60929
/// Watch direct), so a second copy can never work: every bind fails with
/// `NWError 48` and its window sits on 启动失败 with no hint that another copy is
/// already running. A second copy now hands off to the running bridge and exits.
enum SingleInstanceGate {
    static let lockFileName = "bridge-instance.lock"

    private static let logger = AppLog.logger("single-instance")

    /// Held for the lifetime of the process; closing it releases the lock.
    private static var heldDescriptor: Int32?

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WristRemoteBridge", isDirectory: true)
    }

    /// Takes an exclusive non-blocking `flock` on the instance lock file.
    /// Returns the descriptor when this process now owns the bridge, nil when
    /// another process holds it.
    static func acquire(directory: URL) -> Int32? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(lockFileName).path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            logger.error("cannot open the instance lock file")
            return nil
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    static func release(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// Brings the copy that already holds the lock to the front.
    @discardableResult
    static func activateRunningInstance(
        bundleIdentifier: String?,
        excluding pid: pid_t = getpid()
    ) -> Bool {
        guard let bundleIdentifier else { return false }
        let other = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier != pid && !$0.isTerminated }
        guard let other else { return false }
        return other.activate(options: [.activateAllWindows])
    }

    /// Runs once at launch: take the lock, or hand off and exit.
    @MainActor
    static func enforceAtLaunch(
        directory: URL = defaultDirectory,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        if let descriptor = acquire(directory: directory) {
            heldDescriptor = descriptor
            logger.notice("bridge instance lock acquired")
            return
        }
        if activateRunningInstance(bundleIdentifier: bundleIdentifier) {
            logger.notice("another bridge holds the instance lock; activated it and exiting")
            exit(0)
        }
        // The lock is held but nothing can be activated, so the copy may be hung
        // or started from another path: run anyway and let the listeners report
        // the conflict instead of quitting silently.
        logger.error("instance lock is held with no bridge to activate; starting anyway")
    }
}
