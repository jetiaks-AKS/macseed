import Foundation
import Darwin

// An app-local, read-only prerequisite probe. No Core checkout, Python, shell
// profile, inherited PATH or developer tools are needed, including before setup.
enum HomebrewSetupProbe {
    struct Installation {
        let prefix: String
        let repository: String
        var executable: String { repository + "/bin/brew" }
    }
    static let installations = [Installation(prefix: "/opt/homebrew", repository: "/opt/homebrew"),
                                Installation(prefix: "/usr/local", repository: "/usr/local/Homebrew")]
    static func observe() async -> HomebrewObservation {
        await Task.detached(priority: .userInitiated) { inspect() }.value
    }
    static func inspect(installations: [Installation] = installations, searchDirectories: [String]? = nil,
                        read: (String, String) -> NativeHomebrewRead.Result = NativeHomebrewRead.run) -> HomebrewObservation {
        do {
            var found: [Installation] = []
            for installation in installations {
                if try exists(installation.repository) {
                    // Canonical local install locations only. Never execute a PATH
                    // impostor, external symlink, or world-writable installation.
                    for relative in ["", "/bin", "/bin/brew", "/Library", "/Library/Homebrew", "/Library/Homebrew/brew.sh"] {
                        let path = installation.repository + relative
                        guard try exists(path) else { return .broken }
                        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                        guard canonical == path else { return .unknown }
                        var metadata = stat()
                        guard lstat(path, &metadata) == 0 else { return .unknown }
                        guard metadata.st_uid == 0 || metadata.st_uid == geteuid(), metadata.st_mode & 0o002 == 0,
                              metadata.st_mode & 0o020 == 0 || [gid_t(0), gid_t(80)].contains(metadata.st_gid) else { return .unknown }
                        if relative == "/bin/brew", access(path, X_OK) != 0 { return .broken }
                    }
                    found.append(installation)
                }
            }
            // Legacy /usr/local/bin/brew is normally a symlink into Homebrew/bin.
            // Unexpected files/links are an unresolved installation, not absence.
            if installations.map(\.prefix).contains("/usr/local"), try exists("/usr/local/bin/brew") {
                guard found.contains(where: { $0.executable == URL(fileURLWithPath: "/usr/local/bin/brew").resolvingSymlinksInPath().path }) else { return .unknown }
            }
            guard let installation = found.first else {
                // A noncanonical PATH candidate is not trusted enough to execute,
                // but its presence also prevents a false absence/install offer.
                let directories = searchDirectories ?? (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
                    .split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                for directory in Set(directories) {
                    guard directory.hasPrefix("/") else { return .unknown }
                    if try exists(directory + "/brew") { return .unknown }
                }
                return .absent
            }
            let version = read(installation.executable, "--version")
            let prefix = read(installation.executable, "--prefix")
            guard version.complete, prefix.complete else { return .unknown }
            guard version.exitCode == 0, prefix.exitCode == 0 else { return .broken }
            guard version.output.hasPrefix("Homebrew "), version.output.utf8.count <= 256 else { return .broken }
            guard prefix.output.trimmingCharacters(in: .whitespacesAndNewlines) == installation.prefix else { return .unknown }
            return .usable
        } catch { return .unknown }
    }
    private static func exists(_ path: String) throws -> Bool {
        var metadata = stat()
        if lstat(path, &metadata) == 0 { return true }
        if errno == ENOENT { return false }
        throw CocoaError(.fileReadNoPermission)
    }
}

// Short, fixed read commands only. Hold the root unreaped until EOF and a fresh
// process-group check, so deadline cleanup cannot target a recycled process ID.
// Core mutation/supervision paths do not use this reader.
enum NativeHomebrewRead {
    struct Result { let output: String; let exitCode: Int32; let complete: Bool }
    static func run(_ executable: String, _ argument: String) -> Result {
        run(executable, argument, timeout: 2)
    }
    static func run(_ executable: String, _ argument: String, timeout: TimeInterval) -> Result {
        run(executable, arguments: [argument], timeout: timeout)
    }
    // Reuse the same bounded, owned read process for pkgutil/spctl. Startup keeps
    // its original single-argument, stderr-discarding behavior.
    static func run(_ executable: String, arguments input: [String], timeout: TimeInterval,
                    includeStandardError: Bool = false, cancelled: () -> Bool = { false }) -> Result {
        let failed = Result(output: "", exitCode: -1, complete: false)
        let output = Pipe()
        defer { try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close() }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return failed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return failed }
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)
        var mask = sigset_t(); sigemptyset(&mask)
        var defaults = sigset_t(); sigemptyset(&defaults); sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT)
        let codes = [posix_spawnattr_setflags(&attributes, flags), posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawnattr_setsigmask(&attributes, &mask), posix_spawnattr_setsigdefault(&attributes, &defaults),
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            includeStandardError
                ? posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
                : posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO),
            posix_spawn_file_actions_addchdir_np(&actions, "/")]
        guard codes.allSatisfy({ $0 == 0 }) else { return failed }
        let arguments = ([executable] + input).map { $0.withCString { strdup($0) } }
        // Do not inherit Homebrew/Ruby/Bash injection or user shell initialization.
        let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=" + NSHomeDirectory(), "LC_ALL=C",
            "HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_ANALYTICS=1", "HOMEBREW_NO_ANALYTICS_THIS_RUN=1",
            "HOMEBREW_NO_ANALYTICS_MESSAGE_OUTPUT=1", "HOMEBREW_NO_ENV_HINTS=1", "HOMEBREW_NO_SUDO=1",
            "HOMEBREW_NO_ASK=1", "HOMEBREW_NO_INSTALL_FROM_API=1"].map { $0.withCString { strdup($0) } }
        defer { arguments.forEach { free($0) }; environment.forEach { free($0) } }
        var pid: pid_t = 0
        let code = (arguments + [nil]).withUnsafeBufferPointer { argv in
            (environment + [nil]).withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable, &actions, &attributes,
                            UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
            }
        }
        guard code == 0 else { return failed }
        try? output.fileHandleForWriting.close()
        let fd = output.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            _ = kill(-pid, SIGKILL); reapLater(pid); return failed
        }
        var data = Data(), eof = false, exited = false, valid = true
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if cancelled() { valid = false; break }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 { data.append(contentsOf: buffer.prefix(count)); if data.count > 65536 { valid = false; break } }
            else if count == 0 { eof = true }
            else if errno != EAGAIN && errno != EINTR { valid = false; break }
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) != 0 { valid = false; break }
            exited = info.si_pid == pid
            if exited && eof { break }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            _ = poll(&descriptor, 1, 10)
        }
        let children = groupMembers(pid)
        let complete = valid && exited && eof && children == []
        if !complete {
            _ = kill(-pid, SIGTERM)
            Thread.sleep(forTimeInterval: 0.05)
            _ = kill(-pid, SIGKILL)
        }
        var status: Int32 = 0
        let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 0.5
        repeat {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return Result(output: String(decoding: data, as: UTF8.self), exitCode: (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1, complete: complete) }
            if result < 0 && errno != EINTR { return failed }
            Thread.sleep(forTimeInterval: 0.01)
        } while ProcessInfo.processInfo.systemUptime < cleanupDeadline
        // Reap only this still-owned child asynchronously if the OS delays exit.
        reapLater(pid)
        return failed
    }
    private static func reapLater(_ pid: pid_t) {
        DispatchQueue.global().async { var status: Int32 = 0; while waitpid(pid, &status, 0) < 0 && errno == EINTR {} }
    }
    private static func groupMembers(_ group: pid_t) -> [pid_t]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return nil }
        var rows = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
        size = rows.count * MemoryLayout<kinfo_proc>.stride
        let result = rows.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { return nil }
        return rows.prefix(size / MemoryLayout<kinfo_proc>.stride).filter { $0.kp_eproc.e_pgid == group && $0.kp_proc.p_pid != group }.map { $0.kp_proc.p_pid }
    }
}
