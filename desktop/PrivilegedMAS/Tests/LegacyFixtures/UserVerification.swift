import Foundation
import Darwin

// Runs only as the unprivileged Desktop caller. Never opens a helper journal.
enum UserVerification {
    static func validate(_ data: Data, id: String) throws -> String {
        var matches: [[String: Any]] = []
        for line in data.split(separator: 10) where !line.isEmpty {
            let object = try JSONSerialization.jsonObject(with: Data(line))
            guard let rows = (object as? [[String: Any]]) ?? (object as? [String: Any]).map({ [$0] }) else { throw NSError(domain: "inventory", code: 1) }
            matches += rows.filter { ($0["adamID"] as? NSNumber)?.stringValue == id }
        }
        guard matches.count == 1, let row = matches.first,
              let path = row["path"] as? String, path.hasSuffix(".app"),
              let identifier = row["bundleID"] as? String, !identifier.isEmpty,
              let version = row["version"] as? String, !version.isEmpty,
              let bundle = Bundle(path: path), bundle.bundleIdentifier == identifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version,
              FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt/receipt") else {
            throw NSError(domain: "verification_mismatch", code: 1)
        }
        return "user_inventory_id=\(id); bundle=\(identifier); version=\(version); bundle_and_receipt_present; journal_not_modified; service_quiescence_unproven"
    }
    static func run() -> String {
        guard geteuid() != 0 else { return "verification_requires_user_context" }
        // Installed signed app's sealed resource, never a client-supplied path.
        let process = Process(); let pipe = Pipe()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/mas")
        process.arguments = ["list", "--json"]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "MAS_NO_AUTO_INDEX": "1"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            let fd = pipe.fileHandleForReading.fileDescriptor
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { process.terminate(); return "verification_io_failed" }
            var data = Data(); let deadline = ProcessInfo.processInfo.systemUptime + 30
            var eof = false
            while ProcessInfo.processInfo.systemUptime < deadline {
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = read(fd, &bytes, bytes.count)
                if count > 0 { data.append(contentsOf: bytes.prefix(count)) }
                else if count == 0 { eof = true }
                else if errno != EAGAIN && errno != EINTR { throw NSError(domain: "inventory_io", code: 1) }
                guard data.count <= 2 * 1024 * 1024 else { throw NSError(domain: "inventory_limit", code: 1) }
                if !process.isRunning && eof {
                    guard process.terminationReason == .exit && process.terminationStatus == 0 else { return "user_inventory_failed" }
                    return try validate(data, id: Contract.targetID)
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { process.terminate() } // Only this unprivileged read-only child.
            return "user_inventory_timeout; install_not_retried"
        } catch {
            if process.isRunning { process.terminate() }
            return "verification_failed_or_mismatch; install_not_retried; journal_not_modified"
        }
    }
}
