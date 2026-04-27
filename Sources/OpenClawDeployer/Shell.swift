import Foundation

struct CommandResult {
    let exitCode: Int32
    let output: String
}

enum ShellError: Error, LocalizedError {
    case nonZeroExit(command: String, exitCode: Int32)

    var errorDescription: String? {
        switch self {
        case let .nonZeroExit(command, exitCode):
            return "Command failed with exit code \(exitCode): \(command)"
        }
    }
}

struct Shell {
    static func baseEnvironment(extra: [String: String] = [:]) -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var environment = ProcessInfo.processInfo.environment
        let pathParts = [
            "\(home)/.openclaw/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        environment["PATH"] = pathParts.joined(separator: ":")
        for (key, value) in extra {
            environment[key] = value
        }
        return environment
    }

    static func runShell(
        _ command: String,
        environment: [String: String] = baseEnvironment(),
        redactedSecrets: [String] = [],
        log: @escaping (String) -> Void = { _ in }
    ) async -> CommandResult {
        await run(
            executable: "/bin/bash",
            arguments: ["-lc", command],
            environment: environment,
            redactedSecrets: redactedSecrets,
            log: log
        )
    }

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String] = baseEnvironment(),
        redactedSecrets: [String] = [],
        log: @escaping (String) -> Void = { _ in }
    ) async -> CommandResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            let output = OutputBuffer()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = pipe
            process.standardError = pipe

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
                let redacted = redact(chunk, secrets: redactedSecrets)
                output.append(redacted)
                log(redacted)
            }

            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
                if let chunk = String(data: remaining, encoding: .utf8), !chunk.isEmpty {
                    let redacted = redact(chunk, secrets: redactedSecrets)
                    output.append(redacted)
                    log(redacted)
                }
                continuation.resume(returning: CommandResult(exitCode: finished.terminationStatus, output: output.text))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: CommandResult(exitCode: 127, output: error.localizedDescription))
            }
        }
    }

    static func redact(_ text: String, secrets: [String]) -> String {
        secrets.reduce(text) { partial, secret in
            guard !secret.isEmpty else { return partial }
            return partial.replacingOccurrences(of: secret, with: "••••••")
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ text: String) {
        lock.lock()
        storage += text
        lock.unlock()
    }

    var text: String {
        lock.lock()
        let value = storage
        lock.unlock()
        return value
    }
}
