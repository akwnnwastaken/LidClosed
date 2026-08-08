import XCTest
@testable import LidClosed

// MARK: - Test Doubles

/// Records the commands it was asked to run and replays canned results.
final class MockCommandRunner: CommandRunner, @unchecked Sendable {
    var status: Int32
    var output: String
    private(set) var invocations: [String] = []

    init(status: Int32 = 0, output: String = "") {
        self.status = status
        self.output = output
    }

    func run(executableURL: URL, arguments: [String]) throws -> (status: Int32, output: String) {
        invocations.append(([executableURL.path] + arguments).joined(separator: " "))
        return (status, output)
    }
}

final class MockPrivilegedRunner: PrivilegedCommandRunner, @unchecked Sendable {
    var outcome: PrivilegedOutcome
    private(set) var invocations: [String] = []

    init(outcome: PrivilegedOutcome = .success) {
        self.outcome = outcome
    }

    func run(command: String) -> PrivilegedOutcome {
        invocations.append(command)
        return outcome
    }
}

final class MockNotifier: UserNotifier, @unchecked Sendable {
    private(set) var messages: [(title: String, message: String)] = []

    func notify(title: String, message: String, informational: Bool) {
        messages.append((title, message))
    }
}

// MARK: - Tests

@MainActor
final class LidClosedTests: XCTestCase {

    /// Every test gets its own throwaway state file. The production file at
    /// ~/Library/Application Support/LidClosed/state.json is never read or written —
    /// running the suite must not be able to strand a live override.
    private var stateURL: URL!
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LidClosedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        stateURL = tempDir.appendingPathComponent("state.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    /// Builds a manager wired entirely to test doubles. `start()` is never called, so no
    /// signal handlers are installed and no recovery runs.
    private func makeManager(
        pmsetOutput: String = sleepEnabledOutput,
        pmsetStatus: Int32 = 0,
        privileged: PrivilegedOutcome = .success
    ) -> (PowerManager, MockCommandRunner, MockPrivilegedRunner, MockNotifier) {
        let runner = MockCommandRunner(status: pmsetStatus, output: pmsetOutput)
        let privilegedRunner = MockPrivilegedRunner(outcome: privileged)
        let notifier = MockNotifier()
        let manager = PowerManager(
            runner: runner,
            privilegedRunner: privilegedRunner,
            notifier: notifier,
            stateFileURL: stateURL
        )
        return (manager, runner, privilegedRunner, notifier)
    }

    nonisolated private static let sleepDisabledOutput = """
    System-wide power settings:
     SleepDisabled\t\t1
    Currently in use:
     standby              1
    """

    nonisolated private static let sleepEnabledOutput = """
    System-wide power settings:
     SleepDisabled\t\t0
    Currently in use:
     standby              1
    """

    private var stateFileExists: Bool {
        FileManager.default.fileExists(atPath: stateURL.path)
    }

    // MARK: - pmset parsing

    func testParsesSleepDisabled() {
        let (pm, _, _, _) = makeManager(pmsetOutput: Self.sleepDisabledOutput)
        XCTAssertTrue(pm.isSleepDisabledSystemWide)
    }

    func testParsesSleepEnabled() {
        let (pm, _, _, _) = makeManager(pmsetOutput: Self.sleepEnabledOutput)
        XCTAssertFalse(pm.isSleepDisabledSystemWide)
    }

    func testParsesTabSeparatedValue() {
        let (pm, _, _, _) = makeManager(pmsetOutput: "SleepDisabled\t\t1\n")
        XCTAssertTrue(pm.isSleepDisabledSystemWide)
    }

    /// A value of 10 must not be read as 1 — the `\b` anchor guards this.
    func testDoesNotMatchLongerValue() {
        let (pm, _, _, _) = makeManager(pmsetOutput: "SleepDisabled  10\n")
        XCTAssertFalse(pm.isSleepDisabledSystemWide)
    }

    func testNonZeroExitStatusIsNotTreatedAsDisabled() {
        let (pm, _, _, _) = makeManager(pmsetOutput: Self.sleepDisabledOutput, pmsetStatus: 1)
        XCTAssertFalse(pm.isSleepDisabledSystemWide)
    }

    func testUsesAbsolutePmsetPath() {
        let (pm, runner, _, _) = makeManager()
        _ = pm.isSleepDisabledSystemWide
        XCTAssertEqual(runner.invocations, ["/usr/bin/pmset -g"])
    }

    // MARK: - Activation

    func testActivateWritesStateFileOnSuccess() {
        let (pm, _, privileged, notifier) = makeManager(privileged: .success)

        XCTAssertTrue(pm.activate())
        XCTAssertTrue(stateFileExists)
        XCTAssertTrue(pm.isOwnedByUs)
        XCTAssertEqual(privileged.invocations, ["/usr/bin/pmset disablesleep 1"])
        XCTAssertTrue(notifier.messages.isEmpty)
    }

    func testActivateCancelledLeavesNoStateAndNoAlert() {
        let (pm, _, _, notifier) = makeManager(privileged: .cancelled)

        XCTAssertFalse(pm.activate())
        XCTAssertFalse(stateFileExists)
        // Cancelling is a deliberate choice and nothing changed, so nagging is wrong.
        XCTAssertTrue(notifier.messages.isEmpty)
    }

    func testActivateFailureAlertsAndLeavesNoState() {
        let (pm, _, _, notifier) = makeManager(privileged: .failed("boom"))

        XCTAssertFalse(pm.activate())
        XCTAssertFalse(stateFileExists)
        XCTAssertEqual(notifier.messages.count, 1)
    }

    /// If something else already disabled sleep we must not claim it, or a later Disable
    /// would turn off a setting we did not create.
    func testActivateDoesNotClaimExternalOverride() {
        let (pm, _, privileged, notifier) = makeManager(pmsetOutput: Self.sleepDisabledOutput)

        XCTAssertFalse(pm.activate())
        XCTAssertFalse(stateFileExists)
        XCTAssertTrue(privileged.invocations.isEmpty, "must not run pmset at all")
        XCTAssertEqual(notifier.messages.first?.title, "Sleep Is Already Disabled")
    }

    func testActivateIsIdempotentWhenAlreadyOwned() {
        let (pm, _, privileged, _) = makeManager(privileged: .success)
        XCTAssertTrue(pm.activate())
        privileged.outcome = .failed("should not be called")

        XCTAssertTrue(pm.activate())
        XCTAssertEqual(privileged.invocations.count, 1)
    }

    // MARK: - Deactivation

    func testDeactivateRemovesStateFileOnSuccess() {
        let (pm, _, privileged, _) = makeManager(privileged: .success)
        XCTAssertTrue(pm.activate())

        XCTAssertTrue(pm.deactivate())
        XCTAssertFalse(stateFileExists)
        XCTAssertEqual(privileged.invocations.last, "/usr/bin/pmset disablesleep 0")
    }

    /// The original bug: a cancelled disable cleared the marker anyway, so the Mac stayed
    /// awake with nothing left to recover from.
    func testDeactivateCancelledPreservesStateFile() {
        let (pm, _, privileged, notifier) = makeManager(privileged: .success)
        XCTAssertTrue(pm.activate())
        privileged.outcome = .cancelled

        XCTAssertFalse(pm.deactivate())
        XCTAssertTrue(stateFileExists, "state file must survive so the next launch can recover")
        XCTAssertTrue(pm.isOwnedByUs)
        XCTAssertEqual(notifier.messages.last?.title, "Sleep Is Still Disabled")
    }

    func testDeactivateFailurePreservesStateFile() {
        let (pm, _, privileged, _) = makeManager(privileged: .success)
        XCTAssertTrue(pm.activate())
        privileged.outcome = .failed("boom")

        XCTAssertFalse(pm.deactivate())
        XCTAssertTrue(stateFileExists)
    }

    func testDeactivateWithoutOwnershipDoesNothing() {
        let (pm, _, privileged, _) = makeManager(pmsetOutput: Self.sleepDisabledOutput)

        XCTAssertTrue(pm.deactivate())
        XCTAssertTrue(privileged.invocations.isEmpty, "must not touch an override we do not own")
    }

    // MARK: - Silent restore

    func testSilentRestoreRemovesStateFileOnSuccess() {
        let (pm, runner, _, _) = makeManager(privileged: .success)
        XCTAssertTrue(pm.activate())

        runner.status = 0
        pm.attemptSilentRestore()
        XCTAssertFalse(stateFileExists)
        XCTAssertEqual(runner.invocations.last, "/usr/bin/pmset disablesleep 0")
    }

    /// Without root the call fails; the marker must survive for next-launch recovery.
    func testSilentRestoreFailurePreservesStateFile() {
        let (pm, runner, _, _) = makeManager(privileged: .success)
        XCTAssertTrue(pm.activate())

        runner.status = 1
        pm.attemptSilentRestore()
        XCTAssertTrue(stateFileExists)
    }

    func testSilentRestoreDoesNothingWithoutOwnership() {
        let (pm, runner, _, _) = makeManager()
        pm.attemptSilentRestore()
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    // MARK: - External change syncing

    func testSyncClearsStateWhenSleepReEnabledExternally() {
        let (pm, runner, _, _) = makeManager(privileged: .success)
        XCTAssertTrue(pm.activate())
        XCTAssertTrue(pm.isOwnedByUs)

        // Simulates `sudo pmset disablesleep 0` in Terminal.
        runner.output = Self.sleepEnabledOutput
        pm.syncStateWithSystem()

        XCTAssertFalse(stateFileExists)
        XCTAssertFalse(pm.isOwnedByUs)
    }

    /// The menu refreshes on every open, so syncing must not cost two `pmset` spawns.
    func testSyncReturnsSystemStateWithASingleInvocation() {
        let (pm, runner, _, _) = makeManager(pmsetOutput: Self.sleepDisabledOutput)

        XCTAssertTrue(pm.syncStateWithSystem())
        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testSyncKeepsStateWhileOverrideStillActive() {
        let (pm, runner, _, _) = makeManager(privileged: .success)
        XCTAssertTrue(pm.activate())

        runner.output = Self.sleepDisabledOutput
        pm.syncStateWithSystem()

        XCTAssertTrue(stateFileExists)
    }

    // MARK: - State file contents

    func testStateFileRecordsOwningProcess() throws {
        let (pm, _, _, _) = makeManager(privileged: .success)
        XCTAssertTrue(pm.activate())

        let data = try Data(contentsOf: stateURL)
        let state = try JSONDecoder().decode(LidClosedState.self, from: data)
        XCTAssertEqual(state.pid, ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(state.timestamp, Date().timeIntervalSince1970, accuracy: 60)
    }

    /// A truncated or corrupt file still means a previous session disabled sleep, so it
    /// must count as ownership — attempting recovery beats skipping it.
    func testCorruptStateFileStillCountsAsOwnership() throws {
        let (pm, _, _, _) = makeManager()
        try Data().write(to: stateURL)
        XCTAssertTrue(pm.isOwnedByUs)
    }
}
