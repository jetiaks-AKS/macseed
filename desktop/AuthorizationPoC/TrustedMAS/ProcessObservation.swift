import Foundation
import Darwin

// Returned only to the authenticated caller. Unrelated executable paths are never
// exported; paths/identity are exposed only for a detected MAS/helper candidate.
struct ProcessObservation: Codable {
    var effectiveUID = geteuid()
    var reason = "clear_snapshot_apple_services_unproven"
    var pid: Int32?
    var executable: String?
    var identity: String?
    var api: String?
    var errorCode: Int32?
    var checked = 0
    var unsuccessful = 0
    var complete: Bool { reason == "clear_snapshot_apple_services_unproven" }
    var json: String { String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? "observation_encoding_failed" }
}

struct ProcessSample: Equatable {
    let birthSeconds: UInt64
    let birthMicroseconds: UInt64
    let path: String
}
struct ProcessAPIError: Error { let api: String; let code: Int32 }

enum ProcessObserver {
    // Injected API surface is internal, not XPC input. No global mutable probe state.
    static func observe(currentPID: Int32, enumerate: () throws -> [Int32], sample: (Int32) throws -> ProcessSample) -> ProcessObservation {
        var result = ProcessObservation()
        let pids: [Int32]
        do { pids = try enumerate() } catch {
            result.reason = "enumeration_failed"; result.unsuccessful = 1
            let e = error as? ProcessAPIError; result.api = e?.api; result.errorCode = e?.code
            return result
        }
        for pid in pids where pid > 0 {
            do {
                let first = try sample(pid), second = try sample(pid)
                guard first == second else {
                    result.reason = "process_identity_changed"; result.pid = pid; result.unsuccessful += 1
                    return result
                }
                result.checked += 1
                let name = URL(fileURLWithPath: first.path).lastPathComponent
                if name == "mas" || (name == "UIDHelper" && pid != currentPID) {
                    result.reason = name == "mas" ? "active_mas" : "other_helper"
                    result.pid = pid; result.executable = first.path
                    result.identity = "\(first.birthSeconds):\(first.birthMicroseconds)"
                    return result
                }
            } catch {
                // Even ESRCH is an incomplete snapshot; never turn API errors
                // or PID reuse into evidence of absence.
                result.reason = "process_metadata_unavailable"; result.pid = pid; result.unsuccessful += 1
                let e = error as? ProcessAPIError; result.api = e?.api; result.errorCode = e?.code
                return result
            }
        }
        return result
    }
    static func native() -> ProcessObservation {
        observe(currentPID: getpid(), enumerate: {
            errno = 0
            let count = proc_listallpids(nil, 0)
            guard count > 0 else { throw ProcessAPIError(api: "proc_listallpids_size", code: errno) }
            var pids = [Int32](repeating: 0, count: Int(count) + 128)
            errno = 0
            let actual = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
            guard actual > 0, actual < pids.count else { throw ProcessAPIError(api: "proc_listallpids_snapshot", code: actual >= pids.count ? EOVERFLOW : errno) }
            return Array(pids.prefix(Int(actual)))
        }, sample: { pid in
            var info = proc_bsdinfo(); errno = 0
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { throw ProcessAPIError(api: "proc_pidinfo", code: errno) }
            var path = [CChar](repeating: 0, count: 4096); errno = 0
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { throw ProcessAPIError(api: "proc_pidpath", code: errno) }
            return ProcessSample(birthSeconds: info.pbi_start_tvsec, birthMicroseconds: info.pbi_start_tvusec, path: String(cString: path))
        })
    }
}
