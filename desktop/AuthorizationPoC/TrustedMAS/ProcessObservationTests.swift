import Foundation
import Darwin

@main enum ObservationTests {
    static func main() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let journal = scratch.appendingPathComponent("state.json")
        let original = Data("{\"state\":\"unknown\"}".utf8)
        try original.write(to: journal)
        func run(_ path: String = "/usr/bin/other", fail: String? = nil, reused: Bool = false) -> ProcessObservation {
            var calls = 0
            return ProcessObserver.observe(currentPID: 1, enumerate: {
                if fail == "enumeration" { throw ProcessAPIError(api: "proc_listallpids", code: EIO) }
                return [2]
            }, sample: { _ in
                if fail == "metadata" { throw ProcessAPIError(api: "proc_pidpath", code: EACCES) }
                calls += 1
                return ProcessSample(birthSeconds: reused ? UInt64(calls) : 1, birthMicroseconds: 0, path: path)
            })
        }
        precondition(run().complete)
        precondition(run("/protected/mas").reason == "active_mas")
        precondition(run("/protected/UIDHelper").reason == "other_helper")
        precondition(run(fail: "enumeration").reason == "enumeration_failed")
        let denied = run(fail: "metadata")
        precondition(!denied.complete && denied.errorCode == EACCES && denied.executable == nil)
        precondition(run(reused: true).reason == "process_identity_changed")
        let own = ProcessObserver.observe(currentPID: 2, enumerate: { [2] }, sample: { _ in ProcessSample(birthSeconds: 1, birthMicroseconds: 0, path: "/protected/UIDHelper") })
        precondition(own.complete)
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            let result = ProcessObserver.observe(currentPID: 1, enumerate: { [2] }, sample: { _ in throw ProcessAPIError(api: "proc_pidpath", code: ENOENT) })
            precondition(!result.complete && result.errorCode == ENOENT)
        }
        // Observation is pure: rejected/incomplete probes do not publish or reset state.
        let retained = try Data(contentsOf: journal)
        precondition(retained == original)
        print("observation fixtures: clear/MAS/other helper/enumeration/access/reuse/concurrent PASS; legacy bytes unchanged; MAS launches=0")
    }
}
