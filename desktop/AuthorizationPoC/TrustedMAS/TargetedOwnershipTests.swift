import Foundation
import Darwin

// Executable design tests only: NOT used by helper/admission. This model proves
// policy boundaries given evidence, not the native ability to obtain that evidence.
private enum IdentityRead {
    case observed(Child, executableValidated: Bool)
    case unavailable(api: String, errno: Int32)
}
private enum TargetedDecision: Equatable {
    case noOwnedProcessInQualifiedScope
    case ownedPresent
    case unknownNoRetry
}
private struct OwnershipScope {
    let children: [Child]
    // Must originate in durable lifetime tracking, not inferred from current PPID.
    let lifetimeCoverageComplete: Bool
    let unresolvedMutation: Bool
}
private func inspect(_ scope: OwnershipScope?, read: (Int32) -> IdentityRead) -> TargetedDecision {
    guard let scope, scope.lifetimeCoverageComplete, !scope.unresolvedMutation else { return .unknownNoRetry }
    for child in scope.children {
        switch read(child.pid) {
        case .unavailable: return .unknownNoRetry
        case let .observed(observed, validated):
            guard observed == child else { return .unknownNoRetry } // PID reuse / reboot
            // Birth identity establishes the owned instance, not its current code.
            guard validated else { return .unknownNoRetry }
            return .ownedPresent
        }
    }
    // Only a qualified, fully accounted-for scope may be empty. This is NOT
    // global quiescence, foreign-MAS absence, install admission or service completion.
    return .noOwnedProcessInQualifiedScope
}

@main enum TargetedOwnershipTests {
    static func main() throws {
        let child = Child(pid: 123, startSeconds: 10, startMicroseconds: 20, bootSession: "fixture-boot")
        let scope = OwnershipScope(children: [child], lifetimeCoverageComplete: true, unresolvedMutation: false)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let state = scratch.appendingPathComponent("state.json")
        let original = JournalFile.legacyBytes
        try original.write(to: state)
        precondition(inspect(scope, read: { _ in .observed(child, executableValidated: true) }) == .ownedPresent)
        // An unrelated process, even with inaccessible path, is never globally
        // sampled. It is outside a *qualified ownership scope*, not proved harmless.
        var reads: [Int32] = []
        let external = Child(pid: 829, startSeconds: 1, startMicroseconds: 0, bootSession: "fixture-boot")
        let decision = inspect(scope) { pid in
            reads.append(pid)
            if pid == external.pid { return .unavailable(api: "proc_pidpath", errno: ENOENT) }
            return .observed(child, executableValidated: true)
        }
        precondition(decision == .ownedPresent && reads == [123])
        for error in [ENOENT, EPERM] {
            precondition(inspect(scope, read: { _ in .unavailable(api: error == ENOENT ? "proc_pidpath" : "proc_pidinfo", errno: error) }) == .unknownNoRetry)
        }
        let reused = Child(pid: child.pid, startSeconds: 11, startMicroseconds: 0, bootSession: child.bootSession)
        precondition(inspect(scope, read: { _ in .observed(reused, executableValidated: true) }) == .unknownNoRetry)
        precondition(inspect(scope, read: { _ in .observed(child, executableValidated: false) }) == .unknownNoRetry)
        let newBoot = Child(pid: child.pid, startSeconds: child.startSeconds, startMicroseconds: child.startMicroseconds, bootSession: "new-boot")
        precondition(inspect(scope, read: { _ in .observed(newBoot, executableValidated: true) }) == .unknownNoRetry)
        precondition(inspect(nil, read: { _ in preconditionFailure("legacy has no target") }) == .unknownNoRetry)
        for missing in [OwnershipScope(children: [], lifetimeCoverageComplete: false, unresolvedMutation: false), OwnershipScope(children: [], lifetimeCoverageComplete: true, unresolvedMutation: true)] {
            precondition(inspect(missing, read: { _ in preconditionFailure() }) == .unknownNoRetry)
        }
        precondition(inspect(OwnershipScope(children: [], lifetimeCoverageComplete: true, unresolvedMutation: false), read: { _ in preconditionFailure() }) == .noOwnedProcessInQualifiedScope)
        let lock = NSLock(); lock.lock()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in precondition(!lock.try()) }
        lock.unlock()
        precondition(lock.try()); lock.unlock()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            precondition(inspect(scope, read: { _ in .unavailable(api: "proc_pidinfo", errno: EPERM) }) == .unknownNoRetry)
        }
        let retained = try Data(contentsOf: state)
        precondition(retained == original)
        print("targeted ownership policy fixtures PASS: known child, external scope, ENOENT, EPERM, reuse/reboot, unverified code, concurrent/busy, coverage gap, mutation unknown, legacy unknown; legacy bytes unchanged; native fallback NOT qualified")
    }
}
