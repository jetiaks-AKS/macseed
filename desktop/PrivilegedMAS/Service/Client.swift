import Foundation
import Darwin

@main enum Main {
    static func main() {
        guard geteuid() != 0, ((CommandLine.arguments.count == 2 && ["status", "deployment-status"].contains(CommandLine.arguments[1])) || (CommandLine.arguments.count == 3 && ["install", "admission"].contains(CommandLine.arguments[1]) && Contract.validID(CommandLine.arguments[2]))) else { exit(2) }
        let connection = NSXPCConnection(machServiceName: Contract.helper, options: .privileged)
        connection.setCodeSigningRequirement(Contract.requirement(Contract.helper))
        connection.remoteObjectInterface = NSXPCInterface(with: MASServiceProtocol.self)
        let statusOnly = ["status", "deployment-status", "admission"].contains(CommandLine.arguments[1])
        let deploymentStatus = CommandLine.arguments[1] == "deployment-status"
        let lock = NSLock(); var result: String?
        func finish(_ value: String) { lock.lock(); defer { lock.unlock() }; if result == nil { result = value } }
        connection.invalidationHandler = { finish(statusOnly ? "bridge_unavailable" : "unknown_no_retry") }; connection.interruptionHandler = { finish(statusOnly ? "bridge_unavailable" : "unknown_no_retry") }
        connection.resume()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in finish(statusOnly ? "bridge_unavailable" : "unknown_no_retry") } as? MASServiceProtocol
        if CommandLine.arguments[1] == "admission" { proxy?.admission(CommandLine.arguments[2]) { finish($0) } }
        else if statusOnly { proxy?.status { finish($0) } }
        else { proxy?.install(CommandLine.arguments[2]) { finish($0) } }
        let deadline = Date().addingTimeInterval(statusOnly ? 3 : 990)
        while Date() < deadline {
            lock.lock(); let done = result != nil; lock.unlock(); if done { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        lock.lock(); let value = result ?? "unknown_no_retry"; lock.unlock()
        connection.invalidate()
        // No account/vendor output crosses into Core logs.
        if statusOnly {
            if deploymentStatus {
                print(["ready", "unavailable", "busy", "unknown_no_retry"].contains(value) ? value : "bridge_unavailable")
                exit(["ready", "unavailable"].contains(value) ? 0 : 2)
            }
            if value == "unknown_no_retry" || value == "busy" { exit(129) }
            // Before first registration the GUI will request native approval at Execute.
            exit(0)
        }
        if value == "already_present" { exit(10) }
        if value == "succeeded_verified" { exit(0) }
        if ["failed_before_mutation", "invalid_id", "session_refused"].contains(value) { exit(11) }
        if value == "inventory_verified_unknown_no_retry" { exit(133) }
        if value == "unknown_no_retry" { exit(129) }
        exit(2)
    }
}
