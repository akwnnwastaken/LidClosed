import Foundation

/// Protocol to abstract shell command execution, enabling unit testing of PowerManager.
protocol CommandRunner: Sendable {
    /// Executes a command and returns the termination status and standard output.
    func run(executableURL: URL, arguments: [String]) throws -> (status: Int32, output: String)
}

/// Default implementation using Foundation's Process.
struct DefaultCommandRunner: CommandRunner {
    func run(executableURL: URL, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice // Discard stderr for now
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        return (process.terminationStatus, output)
    }
}
