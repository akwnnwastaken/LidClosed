import XCTest
@testable import LidClosed

struct MockCommandRunner: CommandRunner {
    var mockStatus: Int32
    var mockOutput: String
    
    func run(executableURL: URL, arguments: [String]) throws -> (status: Int32, output: String) {
        return (mockStatus, mockOutput)
    }
}

@MainActor
final class LidClosedTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Ensure state file doesn't leak into tests
        let statePath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("LidClosed/state.json")
        try? FileManager.default.removeItem(at: statePath)
    }

    func testPmsetParsing_Active() {
        let output = """
        System-wide power settings:
        SleepDisabled       1
        Currently in use:
        """
        let runner = MockCommandRunner(mockStatus: 0, mockOutput: output)
        let pm = PowerManager(runner: runner)
        
        XCTAssertTrue(pm.isSleepDisabledSystemWide)
    }
    
    func testPmsetParsing_Inactive() {
        let output = """
        System-wide power settings:
        SleepDisabled       0
        Currently in use:
        """
        let runner = MockCommandRunner(mockStatus: 0, mockOutput: output)
        let pm = PowerManager(runner: runner)
        
        XCTAssertFalse(pm.isSleepDisabledSystemWide)
    }
    
    func testPmsetParsing_TabbedActive() {
        let output = "SleepDisabled\t\t1\n"
        let runner = MockCommandRunner(mockStatus: 0, mockOutput: output)
        let pm = PowerManager(runner: runner)
        
        XCTAssertTrue(pm.isSleepDisabledSystemWide)
    }
    
    func testPmsetParsing_FailsIfStatusNotZero() {
        let output = "SleepDisabled       1"
        let runner = MockCommandRunner(mockStatus: 1, mockOutput: output) // Non-zero status
        let pm = PowerManager(runner: runner)
        
        XCTAssertFalse(pm.isSleepDisabledSystemWide)
    }
}
