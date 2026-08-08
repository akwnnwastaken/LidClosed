import Foundation

/// A long-running child process whose lifetime the app manages.
protocol BackgroundProcess: AnyObject {
    var isRunning: Bool { get }
    func terminate()
}

extension Process: BackgroundProcess {}

/// Launches long-running child processes. A seam so `AwakeKeeper` can be tested without
/// actually spawning `caffeinate`.
protocol BackgroundProcessLauncher: Sendable {
    @MainActor func launch(executablePath: String, arguments: [String]) throws -> BackgroundProcess
}

/// Default implementation using Foundation's `Process`.
struct DefaultBackgroundProcessLauncher: BackgroundProcessLauncher {
    @MainActor
    func launch(executablePath: String, arguments: [String]) throws -> BackgroundProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        return process
    }
}
