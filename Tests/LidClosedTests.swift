import XCTest
@testable import LidClosed

// MARK: - Test Doubles

/// Records the commands it was asked to run and replays canned results.
final class MockCommandRunner: CommandRunner, @unchecked Sendable {
    var status: Int32
    var output: String
    var limitsVersion: String?
    private(set) var invocations: [String] = []

    init(status: Int32 = 0, output: String = "") {
        self.status = status
        self.output = output
    }

    func run(executableURL: URL, arguments: [String]) throws -> (status: Int32, output: String) {
        invocations.append(([executableURL.path] + arguments).joined(separator: " "))
        if arguments == ["limits-version", "live-timer"], let limitsVersion { return (0, limitsVersion) }
        return (status, output)
    }
}

final class MockPrivilegedRunner: PrivilegedCommandRunner, @unchecked Sendable {
    var outcome: PrivilegedOutcome
    private(set) var invocations: [String] = []

    init(outcome: PrivilegedOutcome = .success) {
        self.outcome = outcome
    }

    func run(executablePath: String, arguments: [String]) -> PrivilegedOutcome {
        invocations.append(([executablePath] + arguments).joined(separator: " "))
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
    ///
    /// `helperPath` defaults to nil rather than the production path on purpose: with the
    /// real default, every assertion about the privileged command would depend on whether
    /// the machine running the suite happens to have the helper installed.
    private func makeManager(
        pmsetOutput: String = sleepEnabledOutput,
        pmsetStatus: Int32 = 0,
        privileged: PrivilegedOutcome = .success,
        helperPath: String? = nil
    ) -> (PowerManager, MockCommandRunner, MockPrivilegedRunner, MockNotifier) {
        let runner = MockCommandRunner(status: pmsetStatus, output: pmsetOutput)
        let privilegedRunner = MockPrivilegedRunner(outcome: privileged)
        let notifier = MockNotifier()
        let manager = PowerManager(
            runner: runner,
            privilegedRunner: privilegedRunner,
            notifier: notifier,
            stateFileURL: stateURL,
            helperPath: helperPath
        )
        return (manager, runner, privilegedRunner, notifier)
    }

    /// Creates a stand-in for the installed helper. Never executed — `PowerManager` only
    /// decides whether to *address* it, and the privileged runner is a mock.
    private func makeFakeHelper(executable: Bool = true) throws -> String {
        let url = tempDir.appendingPathComponent("com.akwnnwastaken.LidClosed.helper")
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: url.path
        )
        return url.path
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

    // MARK: - Helper routing
    //
    // Which privileged command gets run decides whether a restart cleans up after itself:
    // only the helper writes the root-owned marker the boot daemon reads. Calling pmset
    // directly still disables sleep, so a mistake here is invisible until a reboot leaves
    // the Mac unable to sleep — which is exactly the failure the daemon exists to prevent.

    func testActivateUsesHelperWhenInstalled() throws {
        let helper = try makeFakeHelper()
        let (pm, _, privileged, _) = makeManager(helperPath: helper)

        XCTAssertTrue(pm.activate())
        XCTAssertEqual(privileged.invocations, ["\(helper) enable"])
    }

    func testDeactivateUsesHelperWhenInstalled() throws {
        let helper = try makeFakeHelper()
        let (pm, _, privileged, _) = makeManager(helperPath: helper)

        XCTAssertTrue(pm.activate())
        XCTAssertTrue(pm.deactivate())
        XCTAssertEqual(privileged.invocations, ["\(helper) enable", "\(helper) disable"])
    }

    func testFallsBackToPmsetWhenHelperPathIsNil() {
        let (pm, _, privileged, _) = makeManager(helperPath: nil)

        XCTAssertTrue(pm.activate())
        XCTAssertEqual(privileged.invocations, ["/usr/bin/pmset disablesleep 1"])
    }

    func testFallsBackToPmsetWhenHelperIsMissing() {
        let missing = tempDir.appendingPathComponent("not-installed").path
        let (pm, _, privileged, _) = makeManager(helperPath: missing)

        XCTAssertTrue(pm.activate())
        XCTAssertEqual(privileged.invocations, ["/usr/bin/pmset disablesleep 1"])
    }

    /// A helper present but not executable means a broken or partial install. Addressing it
    /// would fail the privileged call and leave the user unable to switch the mode on at
    /// all, so the direct `pmset` path is the right answer.
    func testFallsBackToPmsetWhenHelperIsNotExecutable() throws {
        let helper = try makeFakeHelper(executable: false)
        let (pm, _, privileged, _) = makeManager(helperPath: helper)

        XCTAssertTrue(pm.activate())
        XCTAssertEqual(privileged.invocations, ["/usr/bin/pmset disablesleep 1"])
    }

    /// The unprivileged restore stays on `pmset` even with the helper installed: the
    /// helper's extra job is clearing a root-owned marker, which needs root just as much.
    func testSilentRestoreStaysOnPmsetWithHelperInstalled() throws {
        let helper = try makeFakeHelper()
        let (pm, runner, _, _) = makeManager(helperPath: helper)

        XCTAssertTrue(pm.activate())
        pm.attemptSilentRestore()
        XCTAssertEqual(runner.invocations.last, "/usr/bin/pmset disablesleep 0")
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

    func testFailedStatusReadKeepsOwnershipDuringPolling() {
        let (pm, runner, _, _) = makeManager()
        XCTAssertTrue(pm.activate())
        runner.status = 1

        XCTAssertTrue(pm.syncStateWithSystem())
        XCTAssertTrue(stateFileExists)
    }

    func testLimitedActivationRequiresUpdatedGuard() throws {
        let helper = try makeFakeHelper()
        let (pm, runner, privileged, notifier) = makeManager(helperPath: helper)
        let limits = SessionLimits(minutes: 30, heat: .serious, battery: 35)

        XCTAssertFalse(pm.activate(limits: limits))
        XCTAssertTrue(privileged.invocations.isEmpty)
        XCTAssertFalse(stateFileExists)
        XCTAssertEqual(notifier.messages.count, 1)

        runner.limitsVersion = "1\n"
        XCTAssertTrue(pm.activate(limits: limits))
        XCTAssertEqual(privileged.invocations, ["\(helper) enable-limited 30 35 2"])
        XCTAssertTrue(stateFileExists)
    }

    func testLimitedActivationDoesNotFallBackToAnUnguardedOverride() {
        let (pm, _, privileged, _) = makeManager()
        XCTAssertFalse(pm.activate(limits: SessionLimits(minutes: 30, battery: 20)))
        XCTAssertTrue(privileged.invocations.isEmpty)
    }

    func testTimerUpdateRequiresAnOwnedSessionAndCompatibleHelper() throws {
        let helper = try makeFakeHelper()
        let (pm, runner, privileged, _) = makeManager(helperPath: helper)
        runner.limitsVersion = "2\n"
        let settings = SessionLimits(minutes: 60)
        XCTAssertFalse(pm.updateTimer(settings))
        XCTAssertTrue(privileged.invocations.isEmpty)
        XCTAssertTrue(pm.activate())

        runner.limitsVersion = "1\n"
        XCTAssertFalse(pm.updateTimer(settings))
        XCTAssertEqual(privileged.invocations, ["\(helper) enable"])

        runner.limitsVersion = "2\n"
        XCTAssertTrue(pm.updateTimer(settings))
        XCTAssertTrue(pm.updateTimer(SessionLimits()))
        XCTAssertEqual(privileged.invocations, [
            "\(helper) enable", "\(helper) set-duration 60", "\(helper) set-duration 0"
        ])
        XCTAssertTrue(stateFileExists)
    }

    func testClockTimerIsSentAsAnAbsoluteDeadlineAndCancelKeepsIt() throws {
        let helper = try makeFakeHelper()
        let (pm, runner, privileged, _) = makeManager(helperPath: helper)
        runner.limitsVersion = "1\n"
        let settings = SessionLimits(heat: .serious, battery: 35, endMinuteOfDay: 18 * 60)
        XCTAssertFalse(pm.activate(limits: settings))
        XCTAssertTrue(privileged.invocations.isEmpty)

        runner.limitsVersion = "2\n"
        XCTAssertTrue(pm.activate(limits: settings))
        let deadline = try XCTUnwrap(pm.activeDeadline)
        XCTAssertEqual(privileged.invocations, [
            "\(helper) enable-until \(Int(deadline.timeIntervalSince1970)) 35 2"
        ])

        privileged.outcome = .cancelled
        XCTAssertFalse(pm.updateTimer(SessionLimits(minutes: 30)))
        XCTAssertEqual(pm.activeDeadline, deadline)
        XCTAssertTrue(stateFileExists)

        privileged.outcome = .success
        let update = SessionLimits(endMinuteOfDay: 20 * 60)
        XCTAssertTrue(pm.updateTimer(update))
        let updated = try XCTUnwrap(pm.activeDeadline)
        XCTAssertEqual(privileged.invocations.last,
                       "\(helper) set-deadline \(Int(updated.timeIntervalSince1970))")
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

// MARK: - Privileged command quoting

@MainActor
final class PrivilegedQuotingTests: XCTestCase {

    private typealias Runner = AppleScriptPrivilegedRunner

    func testBuildsQuotedScriptForNormalArguments() {
        let source = Runner.scriptSource("/usr/bin/pmset", ["disablesleep", "1"])
        XCTAssertEqual(
            source,
            "do shell script \"'/usr/bin/pmset' 'disablesleep' '1'\" with administrator privileges"
        )
    }

    /// A semicolon inside an argument must stay inside the quotes, not start a new command.
    func testShellMetacharactersCannotStartASecondCommand() {
        let quoted = Runner.shellQuoted("1; rm -rf /")
        XCTAssertEqual(quoted, "'1; rm -rf /'")
    }

    /// The classic break-out attempt: a single quote to close our quoting early.
    func testEmbeddedSingleQuoteIsNeutralised() {
        let quoted = Runner.shellQuoted("a'b")
        XCTAssertEqual(quoted, #"'a'\''b'"#)
    }

    func testDoubleQuoteIsEscapedForAppleScript() {
        XCTAssertEqual(Runner.appleScriptEscaped("say \"hi\""), "say \\\"hi\\\"")
    }

    /// Backslashes must be doubled before quotes are escaped, or the escapes get escaped.
    func testBackslashIsEscapedBeforeQuotes() {
        XCTAssertEqual(Runner.appleScriptEscaped(#"a\"b"#), #"a\\\"b"#)
    }

    /// An argument carrying both quote styles must not be able to close the AppleScript
    /// string literal early. Strip every escape sequence and the only double quotes left
    /// should be the two delimiters.
    func testHostileArgumentCannotTerminateTheAppleScriptString() {
        let source = Runner.scriptSource("/usr/bin/pmset", [#"x" ; touch /tmp/pwned ; echo '"#])

        var stripped = source.replacingOccurrences(of: #"\\"#, with: "")
        stripped = stripped.replacingOccurrences(of: #"\""#, with: "")

        XCTAssertEqual(
            stripped.filter { $0 == "\"" }.count, 2,
            "only the opening and closing delimiters may be unescaped quotes"
        )
    }

    /// Round-trip through a real shell: whatever we quote must arrive at the program as one
    /// intact argument, with no second command executed. This is the property the whole
    /// argument-array API exists to guarantee.
    func testQuotedArgumentsSurviveARealShellIntact() throws {
        let hostile = [
            "1; echo INJECTED",
            "a'b",
            #"x" ; echo INJECTED ; echo '"#,
            "$(echo INJECTED)",
            "`echo INJECTED`",
            "back\\slash",
            "spaces and 'quotes'"
        ]

        let shellCommand = (["/bin/echo"] + hostile)
            .map(Runner.shellQuoted)
            .joined(separator: " ")

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", shellCommand]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()

        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(output, hostile.joined(separator: " "))
        XCTAssertFalse(output?.contains("INJECTED\n") ?? true, "no argument may execute as a command")
    }
}

// MARK: - Battery guard

/// Exercises the helper's `battery-low` subcommand, which is the single place the low-battery
/// decision is made — both the minute-by-minute guard and the refusal in `enable` go through
/// it. It only parses stdin, so the real script can be run here without root.
final class BatteryGuardTests: XCTestCase {

    private static let helperURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts/lidclosed-helper.sh")

    /// Captured from a real `pmset -g batt`, with the percentage and source substituted.
    private func batt(_ source: String, _ percent: Int) -> String {
        """
        Now drawing from '\(source)'
         -InternalBattery-0 (id=22937699)\t\(percent)%; discharging; 1:10 remaining present: true

        """
    }

    private func run(_ arguments: [String], _ input: String) throws -> (Int32, String) {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [Self.helperURL.path] + arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    private func isLow(_ input: String) throws -> Bool {
        try run(["battery-low"], input).0 == 0
    }

    func testHealthyBatteryIsNotLow() throws {
        XCTAssertFalse(try isLow(batt("Battery Power", 81)))
    }

    func testThresholdItselfCountsAsLow() throws {
        XCTAssertTrue(try isLow(batt("Battery Power", 20)))
    }

    func testJustAboveThresholdIsNotLow() throws {
        XCTAssertFalse(try isLow(batt("Battery Power", 21)))
    }

    func testSingleDigitPercentageIsLow() throws {
        XCTAssertTrue(try isLow(batt("Battery Power", 5)))
    }

    /// Plugged in, the battery level is irrelevant: the Mac cannot run flat.
    func testLowChargeOnACPowerIsNotLow() throws {
        XCTAssertFalse(try isLow(batt("AC Power", 5)))
    }

    /// A desktop reports AC power and has no battery line at all.
    func testDesktopWithoutBatteryIsNotLow() throws {
        XCTAssertFalse(try isLow("Now drawing from 'AC Power'\n"))
    }

    /// Output that cannot be parsed must leave things as they are, not restore sleep under a
    /// user on the strength of a guess.
    func testUnparseableOutputIsNotLow() throws {
        XCTAssertFalse(try isLow(""))
        XCTAssertFalse(try isLow("Now drawing from 'Battery Power'\n -InternalBattery-0 garbage\n"))
    }

    func testSessionGuardStopsAtTheDeadlineEvenOnACPower() throws {
        XCTAssertEqual(try run(["limits-check", "100", "100", "35", "2", "0"], batt("AC Power", 90)).1,
                       "Time limit reached.\n")
        XCTAssertEqual(try run(["limits-check", "99", "100", "35", "2", "0"], batt("AC Power", 90)).1, "")
    }

    func testSessionGuardUsesThermalLevelAndCustomUnpluggedBatteryLimit() throws {
        XCTAssertEqual(try run(["limits-check", "100", "0", "35", "2", "2"], batt("AC Power", 90)).1,
                       "Thermal limit reached.\n")
        XCTAssertTrue(try run(["limits-check", "100", "0", "35", "2", ""], batt("Battery Power", 35)).1.contains("35%"))
        XCTAssertEqual(try run(["limits-check", "100", "0", "35", "2", "1"], batt("AC Power", 35)).1, "")
        XCTAssertEqual(try run(["limits-check", "100", "0", "35", "2", "1"], batt("Battery Power", 36)).1, "")
    }

    func testSessionGuardRejectsMalformedLimitArguments() throws {
        for invalid in ["-1", "101", "035", "3+4", "0"] {
            XCTAssertEqual(try run(["limits-check", "100", "0", invalid, "0", ""], "").0, 64)
        }
    }
}

// MARK: - Keep-awake option

final class MockBackgroundProcess: BackgroundProcess, @unchecked Sendable {
    var isRunning = true
    private(set) var terminateCallCount = 0

    func terminate() {
        terminateCallCount += 1
        isRunning = false
    }
}

final class MockProcessLauncher: BackgroundProcessLauncher, @unchecked Sendable {
    private(set) var invocations: [[String]] = []
    var shouldThrow = false
    var lastProcess: MockBackgroundProcess?

    struct LaunchFailure: Error {}

    func launch(executablePath: String, arguments: [String]) throws -> BackgroundProcess {
        invocations.append([executablePath] + arguments)
        if shouldThrow { throw LaunchFailure() }
        let process = MockBackgroundProcess()
        lastProcess = process
        return process
    }
}

@MainActor
final class AwakeKeeperTests: XCTestCase {

    func testStartsCaffeinateBoundToOurPid() {
        let launcher = MockProcessLauncher()
        let keeper = AwakeKeeper(launcher: launcher)

        XCTAssertTrue(keeper.start())
        XCTAssertTrue(keeper.isActive)

        let expected = [
            "/usr/bin/caffeinate",
            "-dimsu",
            "-w",
            String(ProcessInfo.processInfo.processIdentifier)
        ]
        XCTAssertEqual(launcher.invocations, [expected])
    }

    func testStartIsIdempotent() {
        let launcher = MockProcessLauncher()
        let keeper = AwakeKeeper(launcher: launcher)

        XCTAssertTrue(keeper.start())
        XCTAssertTrue(keeper.start())
        XCTAssertEqual(launcher.invocations.count, 1)
    }

    func testStopTerminatesTheChild() {
        let launcher = MockProcessLauncher()
        let keeper = AwakeKeeper(launcher: launcher)
        XCTAssertTrue(keeper.start())

        keeper.stop()
        XCTAssertFalse(keeper.isActive)
        XCTAssertEqual(launcher.lastProcess?.terminateCallCount, 1)
    }

    func testStopIsSafeWhenNotRunning() {
        let keeper = AwakeKeeper(launcher: MockProcessLauncher())
        keeper.stop()
        XCTAssertFalse(keeper.isActive)
    }

    func testLaunchFailureLeavesKeeperInactive() {
        let launcher = MockProcessLauncher()
        launcher.shouldThrow = true
        let notifier = MockNotifier()
        let keeper = AwakeKeeper(launcher: launcher, notifier: notifier)

        XCTAssertFalse(keeper.start())
        XCTAssertFalse(keeper.isActive)
        XCTAssertEqual(notifier.messages.count, 1)
    }

    /// A child that exited on its own must not still read as active.
    func testChildExitingOnItsOwnClearsActiveState() {
        let launcher = MockProcessLauncher()
        let keeper = AwakeKeeper(launcher: launcher)
        XCTAssertTrue(keeper.start())

        launcher.lastProcess?.isRunning = false
        XCTAssertFalse(keeper.isActive)
    }

    func testTimedSessionStopsAtItsDeadlineAndStillBindsChildToApp() throws {
        let launcher = MockProcessLauncher()
        let keeper = AwakeKeeper(launcher: launcher)
        XCTAssertTrue(keeper.start(limits: SessionLimits(minutes: 15)))
        let deadline = try XCTUnwrap(keeper.deadline)
        XCTAssertNil(keeper.enforceLimits(now: deadline.addingTimeInterval(-1)))
        XCTAssertTrue(keeper.isActive)
        XCTAssertEqual(launcher.invocations.first?.suffix(2), ["-w", String(ProcessInfo.processInfo.processIdentifier)][...])

        XCTAssertNotNil(keeper.enforceLimits(now: deadline))
        XCTAssertFalse(keeper.isActive)
        XCTAssertEqual(launcher.lastProcess?.terminateCallCount, 1)
    }

    func testChangingDurationStartsAFullNewCountdownOnTheSameChild() throws {
        let launcher = MockProcessLauncher()
        let keeper = AwakeKeeper(launcher: launcher, runner: MockCommandRunner())
        XCTAssertTrue(keeper.start(limits: SessionLimits(minutes: 30, battery: 20)))
        let oldDeadline = try XCTUnwrap(keeper.deadline)
        let editTime = oldDeadline.addingTimeInterval(-10 * 60)
        let settings = SessionLimits(minutes: 60)
        XCTAssertFalse(keeper.updateTimer(settings, now: oldDeadline))
        XCTAssertTrue(keeper.updateTimer(settings, now: editTime))
        let newDeadline = editTime.addingTimeInterval(60 * 60)
        XCTAssertEqual(keeper.deadline, newDeadline)
        XCTAssertEqual(keeper.limits.battery, 20)
        XCTAssertNil(keeper.enforceLimits(now: oldDeadline))

        XCTAssertTrue(keeper.updateTimer(settings, now: oldDeadline))
        XCTAssertEqual(keeper.deadline, newDeadline)
        XCTAssertTrue(keeper.updateTimer(SessionLimits(), now: oldDeadline))
        XCTAssertNil(keeper.deadline)
        XCTAssertTrue(keeper.updateTimer(SessionLimits(minutes: 15), now: oldDeadline))
        XCTAssertEqual(keeper.deadline, oldDeadline.addingTimeInterval(15 * 60))
        XCTAssertNotNil(keeper.enforceLimits(now: oldDeadline.addingTimeInterval(15 * 60)))
        XCTAssertEqual(launcher.invocations.count, 1)
        XCTAssertEqual(launcher.lastProcess?.terminateCallCount, 1)
    }

    func testThermalLimitRefusesHotStartAndStopsRunningSession() {
        let launcher = MockProcessLauncher()
        let notifier = MockNotifier()
        var state = ProcessInfo.ThermalState.serious
        let keeper = AwakeKeeper(launcher: launcher, notifier: notifier, thermalState: { state })
        let limits = SessionLimits(heat: .serious)
        XCTAssertFalse(keeper.start(limits: limits))
        XCTAssertTrue(launcher.invocations.isEmpty)
        XCTAssertEqual(notifier.messages.count, 1)

        state = .fair
        XCTAssertTrue(keeper.start(limits: limits))
        state = .critical
        XCTAssertNotNil(keeper.enforceLimits())
        XCTAssertFalse(keeper.isActive)
    }

    func testBatteryLimitStopsOnlyWhileUnplugged() {
        let runner = MockCommandRunner(output: "Now drawing from 'AC Power'\n -InternalBattery-0 25%; charging")
        let keeper = AwakeKeeper(launcher: MockProcessLauncher(), runner: runner)
        XCTAssertTrue(keeper.start(limits: SessionLimits(battery: 25)))
        XCTAssertNil(keeper.enforceLimits())
        runner.output = "Now drawing from 'Battery Power'\n -InternalBattery-0 25%; discharging"
        XCTAssertNotNil(keeper.enforceLimits())
        XCTAssertFalse(keeper.isActive)
    }
}

final class ClockTimerTests: XCTestCase {
    func testClockTimeUsesTodayOrTomorrowAsNeeded() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 7200)!
        func date(_ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)))
        }
        let limits = SessionLimits(endMinuteOfDay: 18 * 60)
        XCTAssertEqual(limits.deadline(from: try date(7, 17, 30), calendar: calendar), try date(7, 18, 0))
        XCTAssertEqual(limits.deadline(from: try date(7, 18, 0), calendar: calendar), try date(8, 18, 0))
        XCTAssertEqual(limits.deadline(from: try date(7, 23, 55), calendar: calendar), try date(8, 18, 0))
    }

    func testExistingSavedDurationStillDecodesWithoutClockSetting() throws {
        let data = Data(#"{"minutes":30,"heat":0,"battery":20}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(SessionLimits.self, from: data),
                       SessionLimits(minutes: 30, battery: 20))
    }
}

// MARK: - Single instance lock

final class InstanceLockTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testFirstAcquisitionSucceeds() {
        let lock = InstanceLock(lockFileURL: tempDir.appendingPathComponent("instance.lock"))
        XCTAssertTrue(lock.tryAcquire())
    }

    /// The second holder of the same lock file must be refused — this is what stops a
    /// second instance from treating a live override as stale.
    func testSecondAcquisitionOfSameFileIsRefused() {
        let url = tempDir.appendingPathComponent("instance.lock")
        let first = InstanceLock(lockFileURL: url)
        let second = InstanceLock(lockFileURL: url)

        XCTAssertTrue(first.tryAcquire())
        XCTAssertFalse(second.tryAcquire())
    }

    func testDifferentLockFilesDoNotConflict() {
        let a = InstanceLock(lockFileURL: tempDir.appendingPathComponent("a.lock"))
        let b = InstanceLock(lockFileURL: tempDir.appendingPathComponent("b.lock"))

        XCTAssertTrue(a.tryAcquire())
        XCTAssertTrue(b.tryAcquire())
    }

    func testCreatesMissingParentDirectory() {
        let nested = tempDir
            .appendingPathComponent("does/not/exist", isDirectory: true)
            .appendingPathComponent("instance.lock")

        XCTAssertTrue(InstanceLock(lockFileURL: nested).tryAcquire())
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }
}

// MARK: - Status line

@MainActor
final class StatusTextTests: XCTestCase {

    private func text(sleepDisabled: Bool, owned: Bool, keepingAwake: Bool) -> String {
        StatusBarController.statusText(
            isSleepDisabled: sleepDisabled,
            isOwnedByUs: owned,
            isKeepingAwake: keepingAwake
        )
    }

    func testNothingActive() {
        XCTAssertEqual(
            text(sleepDisabled: false, owned: false, keepingAwake: false),
            "○ Inactive — normal sleep behavior"
        )
    }

    /// Keep Awake alone must say the lid is still a way to put the Mac to sleep.
    func testKeepAwakeOnly() {
        XCTAssertEqual(
            text(sleepDisabled: false, owned: false, keepingAwake: true),
            "◐ Awake — but sleeps if you close the lid"
        )
    }

    /// Locking the screen with only lid-closed mode on turns the display off, so the line
    /// must not imply the display is safe.
    func testLidClosedModeOnly() {
        XCTAssertEqual(
            text(sleepDisabled: true, owned: true, keepingAwake: false),
            "● Awake with the lid closed — display can still turn off"
        )
    }

    func testBothActive() {
        XCTAssertEqual(
            text(sleepDisabled: true, owned: true, keepingAwake: true),
            "● Awake with the lid closed — display stays on too"
        )
    }

    func testExternalOverrideAlone() {
        XCTAssertEqual(
            text(sleepDisabled: true, owned: false, keepingAwake: false),
            "● Sleep disabled outside LidClosed — display can still turn off"
        )
    }

    /// Keep Awake still changes the display outcome while sleep is disabled, so it must
    /// change the line there too.
    func testKeepAwakeAltersTheLineEvenWhileSleepIsDisabled() {
        XCTAssertNotEqual(
            text(sleepDisabled: true, owned: true, keepingAwake: true),
            text(sleepDisabled: true, owned: true, keepingAwake: false)
        )
    }

    /// Every combination must produce a distinct line: a state the user cannot distinguish
    /// is a state they cannot act on.
    func testAllSixCombinationsAreDistinct() {
        var seen = Set<String>()
        for sleepDisabled in [false, true] {
            for owned in [false, true] {
                for keepingAwake in [false, true] {
                    // Ownership is only meaningful while sleep is disabled.
                    guard sleepDisabled || !owned else { continue }
                    seen.insert(text(sleepDisabled: sleepDisabled, owned: owned, keepingAwake: keepingAwake))
                }
            }
        }
        XCTAssertEqual(seen.count, 6)
    }
}
