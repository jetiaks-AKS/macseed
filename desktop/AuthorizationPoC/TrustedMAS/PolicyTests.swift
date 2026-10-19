import Foundation
import Darwin

@main enum Tests {
    static func main() throws {
        precondition(Contract.admission("deploy", uid: 501, console: 501, graphical: true))
        for operation in ["install", "get", "reset", "/bin/sh", "version --anything"] {
            precondition(!Contract.admission(operation, uid: 501, console: 501, graphical: true))
        }
        precondition(!Contract.admission("list", uid: 0, console: 0, graphical: true))
        precondition(!Contract.admission("list", uid: 501, console: 502, graphical: true))
        precondition(!Contract.admission("list", uid: 501, console: 501, graphical: false))
        precondition(!Contract.allowsStart("running"))
        precondition(!Contract.allowsStart("unknown"))
        precondition(!Contract.allowsStart("invalid"))
        precondition(Contract.allowsStart("completed"))
        try checkCode("/private/tmp/macseed-mas-swift64-artifact/mas")
        do { try checkCode("/bin/echo"); preconditionFailure("foreign executable accepted") } catch {}
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let path = scratch.appendingPathComponent("tampered")
        var data = try Data(contentsOf: URL(fileURLWithPath: "/private/tmp/macseed-mas-swift64-artifact/mas"))
        data[4096] ^= 1
        try data.write(to: path)
        do { try checkCode(path.path); preconditionFailure("tampered executable accepted") } catch {}
        let descriptor = open(scratch.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        precondition(descriptor >= 0); defer { close(descriptor) }
        try requireNoACL(descriptor)
        print("admission and restart policy checks passed")
    }
}
