import AppKit
import CryptoKit
import Foundation
import Security
import Darwin

// This client only acquires the official Homebrew installer. It is not a Core
// install provider, updater or privileged helper.
enum HomebrewPackageError: Error, Equatable {
    case download(String), verification(String), launch(String)
    var message: String {
        switch self { case .download(let text), .verification(let text), .launch(let text): text }
    }
}

struct HomebrewDownloadPlan: Equatable, Sendable {
    static let endpoint = URL(string: "https://api.github.com/repos/Homebrew/brew/releases/latest")!
    static let maximumSize: Int64 = 512 * 1024 * 1024
    let releaseID: Int64
    let version: String
    let assetID: Int64
    let url: URL
    let sha256: String
    let size: Int64

    private struct Release: Decodable {
        let id: Int64, tag_name: String, url: String, html_url: String, assets_url: String
        let draft: Bool, prerelease: Bool
        let published_at: String
        let assets: [Asset]
    }
    private struct Asset: Decodable {
        let id: Int64, name: String, url: String, browser_download_url: String
        let size: Int64, digest: String?, state: String
    }
    static func parse(_ data: Data) throws -> Self {
        let invalid = HomebrewPackageError.download("Official release information is incomplete or inconsistent. Try again later or use the official download page.")
        guard data.count <= 2 * 1024 * 1024,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              release.id > 0, !release.draft, !release.prerelease,
              release.tag_name.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
              ISO8601DateFormatter().date(from: release.published_at) != nil,
              release.url == "https://api.github.com/repos/Homebrew/brew/releases/\(release.id)",
              release.assets_url == release.url + "/assets",
              release.html_url == "https://github.com/Homebrew/brew/releases/tag/" + release.tag_name else { throw invalid }
        let assets = release.assets.filter { $0.name == "Homebrew.pkg" }
        guard assets.count == 1, let asset = assets.first, asset.id > 0, asset.state == "uploaded",
              asset.size > 0, asset.size <= maximumSize,
              asset.url == "https://api.github.com/repos/Homebrew/brew/releases/assets/\(asset.id)",
              asset.browser_download_url == "https://github.com/Homebrew/brew/releases/download/\(release.tag_name)/Homebrew.pkg",
              let url = URL(string: asset.browser_download_url),
              let digest = asset.digest, digest.range(of: #"^sha256:[a-f0-9]{64}$"#, options: .regularExpression) != nil else { throw invalid }
        return Self(releaseID: release.id, version: release.tag_name, assetID: asset.id,
                    url: url, sha256: String(digest.dropFirst(7)), size: asset.size)
    }

    func permitsDownloadURL(_ candidate: URL) -> Bool {
        guard let parts = URLComponents(url: candidate, resolvingAgainstBaseURL: false), parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil else { return false }
        if candidate == url { return true }
        // The official Homebrew/brew repository is GitHub repository 53238813.
        // Only a redirect from its validated release URL may reach this CDN.
        return parts.host == "release-assets.githubusercontent.com"
            && parts.percentEncodedPath.range(of: #"^/github-production-release-asset/53238813/[a-f0-9-]+$"#, options: .regularExpression) != nil
    }
}

// One serial delegate owns the stream, file, deadline and continuation. No task
// uses URLSession's unbounded in-memory data APIs or its implicit download cache.
final class HomebrewPackageTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let queue: OperationQueue = { let value = OperationQueue(); value.maxConcurrentOperationCount = 1; return value }()
    private let plan: HomebrewDownloadPlan?
    private let target: URL?
    private let progress: @Sendable (Int64) -> Void
    private let configuration: URLSessionConfiguration
    private let duration: TimeInterval
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var stream: FileHandle?
    private var data = Data()
    private var received: Int64 = 0
    private var lastProgress: TimeInterval = 0
    private var redirects = 0
    private var stopped = false
    private var responseAccepted = false
    private var deadline: DispatchWorkItem?
    private var limit: Int64 { plan?.size ?? 2 * 1024 * 1024 }
    init(plan: HomebrewDownloadPlan? = nil, target: URL? = nil,
         configuration: URLSessionConfiguration = .ephemeral, duration: TimeInterval? = nil,
         progress: @escaping @Sendable (Int64) -> Void = { _ in }) {
        self.plan = plan; self.target = target; self.progress = progress; self.configuration = configuration
        self.duration = duration ?? (plan == nil ? 30 : 900)
    }
    func run() async throws -> Data {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation { [self] in
                    guard !stopped else { continuation.resume(throwing: CancellationError()); return }
                    self.continuation = continuation
                    do {
                        if let target {
                            let fd = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                            guard fd >= 0 else { throw HomebrewPackageError.download("Couldn’t create private download storage. Check free disk space and try again.") }
                            stream = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                        }
                        configuration.timeoutIntervalForRequest = min(30, duration)
                        configuration.timeoutIntervalForResource = duration
                        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
                        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                        var request = URLRequest(url: plan?.url ?? HomebrewDownloadPlan.endpoint)
                        request.setValue("Macseed-Homebrew-Setup", forHTTPHeaderField: "User-Agent")
                        request.setValue(plan == nil ? "application/vnd.github+json" : "application/octet-stream", forHTTPHeaderField: "Accept")
                        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                        if plan == nil { request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version") }
                        let timeout = DispatchWorkItem { [weak self] in
                            self?.queue.addOperation { [weak self] in self?.finish(.failure(HomebrewPackageError.download("The download timed out. Check your connection and retry."))) }
                        }
                        deadline = timeout
                        DispatchQueue.global().asyncAfter(deadline: .now() + duration, execute: timeout)
                        session!.dataTask(with: request).resume()
                    } catch { finish(.failure(error)) }
                }
            }
        }, onCancel: { [self] in queue.addOperation { [self] in finish(.failure(CancellationError())) } })
    }
    private func finish(_ result: Result<Data, Error>) {
        guard !stopped else { return }
        stopped = true; deadline?.cancel(); deadline = nil
        try? stream?.close(); stream = nil
        session?.invalidateAndCancel(); session = nil
        let completion = continuation; continuation = nil
        completion?.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard !stopped, let plan, redirects <= 3, let url = request.url,
              let previous = response.url, plan.permitsDownloadURL(previous), plan.permitsDownloadURL(url) else {
            completionHandler(nil)
            finish(.failure(HomebrewPackageError.download("The download was redirected outside the approved Homebrew release infrastructure."))); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !stopped, let response = response as? HTTPURLResponse, response.statusCode == 200,
              let url = response.url, plan.map({ $0.permitsDownloadURL(url) }) ?? (url == HomebrewDownloadPlan.endpoint),
              response.expectedContentLength <= limit,
              response.value(forHTTPHeaderField: "Content-Encoding").map({ $0 == "identity" }) ?? true,
              plan == nil || response.expectedContentLength == -1 || response.expectedContentLength == limit else {
            completionHandler(.cancel)
            finish(.failure(HomebrewPackageError.download("The server returned an unexpected response or package size. Retry or use the official download page."))); return
        }
        responseAccepted = true; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard !stopped, responseAccepted else { return }
        guard Int64(chunk.count) <= limit - received else {
            finish(.failure(HomebrewPackageError.download("The download exceeded its expected size."))); return
        }
        do {
            if let stream { try stream.write(contentsOf: chunk) } else { data.append(chunk) }
            received += Int64(chunk.count)
            let now = ProcessInfo.processInfo.systemUptime
            if received == limit || now - lastProgress >= 0.1 { progress(received); lastProgress = now }
        } catch { finish(.failure(HomebrewPackageError.download("Couldn’t save the download. Check free disk space and retry."))) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !stopped else { return }
        if let error {
            finish(.failure((error as? URLError)?.code == .cancelled ? CancellationError()
                : HomebrewPackageError.download("The download was interrupted. Check your connection and retry.")))
        } else if !responseAccepted || received == 0 || (plan != nil && received != limit) {
            finish(.failure(HomebrewPackageError.download("The download is incomplete. Retry to obtain a fresh package.")))
        } else { finish(.success(data)) }
    }
}

// A handed-off package can outlive both the window and Macseed, including an
// uncertain open error. Only a different kernel boot session proves all of its
// possible Installer/installerd readers are gone. Never use an age/PID heuristic.
final class HomebrewPackageStaging {
    static let maximumEntries = 4 // At most 4 * 512 MiB of managed package data.
    static var bootSession: UUID? {
        var bytes = [CChar](repeating: 0, count: 128), size = 128
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
        return UUID(uuidString: String(cString: bytes))
    }
    private static var defaultBase: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.macseed.desktop.HomebrewPackages", isDirectory: true)
    }
    let directory: URL
    private let session: UUID
    private let lease: Int32
    private var retained = false
    var partial: URL { directory.appendingPathComponent("Homebrew.pkg.partial") }
    var package: URL { directory.appendingPathComponent("Homebrew.pkg") }

    private static func privateDirectory(_ path: URL) -> Bool {
        var info = stat()
        return lstat(path.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
            && info.st_uid == geteuid() && info.st_mode & 0o077 == 0
    }
    private static func openPrivate(_ path: URL, exclusive: Bool = false) throws -> Int32 {
        let fd = Darwin.open(path.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | (exclusive ? O_EXCL : 0), 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            Darwin.close(fd); throw CocoaError(.fileWriteNoPermission)
        }
        return fd
    }
    private static func lockBase(_ base: URL) throws -> Int32 {
        guard privateDirectory(base) else { throw CocoaError(.fileWriteNoPermission) }
        let fd = try openPrivate(base.appendingPathComponent(".cache-lock"))
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw HomebrewPackageError.download("Another package operation is using the cache. Please retry.")
        }
        return fd
    }
    private static func entries(_ base: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("download-") }
    }
    private static func markRetained(_ directory: URL, session: UUID) throws {
        let fd = try openPrivate(directory.appendingPathComponent("retained-boot"), exclusive: true)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(session.uuidString.utf8))
    }
    // Caller holds the base lock. Active acquisitions keep a separate flock;
    // another window/process cannot sweep them, even after its own restart.
    private static func sweep(_ base: URL, session: UUID) throws {
        for directory in try entries(base) {
            guard directory.lastPathComponent.range(of: #"^download-[A-Za-z0-9]{6}$"#, options: .regularExpression) != nil,
                  privateDirectory(directory),
                  let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
                  files.allSatisfy({ file in
                      var info = stat()
                      return ["Homebrew.pkg", "Homebrew.pkg.partial", ".lease", "retained-boot",
                              "certificate-0.der", "certificate-1.der", "certificate-2.der"].contains(file.lastPathComponent)
                          && lstat(file.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
                          && info.st_uid == geteuid() && info.st_nlink == 1
                  }) else { continue }
            let legacy = !files.contains { $0.lastPathComponent == ".lease" }
            let marker = directory.appendingPathComponent("retained-boot")
            let hasMarker = files.contains { $0.lastPathComponent == "retained-boot" }
            if legacy && !hasMarker {
                // Mark before creating a lease, so a crash cannot make a legacy
                // Installer package look like an abandoned new acquisition.
                try? markRetained(directory, session: session)
                continue
            }
            guard let fd = try? openPrivate(directory.appendingPathComponent(".lease")) else { continue }
            defer { Darwin.close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            if hasMarker {
                // Malformed/unknown ownership is retained, never guessed away.
                guard let data = try? Data(contentsOf: marker), data.count == 36,
                      let text = String(data: data, encoding: .utf8), let prior = UUID(uuidString: text),
                      prior != session else { continue }
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }
    static func cleanup(base: URL? = nil, bootSession: UUID? = HomebrewPackageStaging.bootSession) {
        let base = base ?? defaultBase
        guard let bootSession, let lock = try? lockBase(base) else { return }
        defer { Darwin.close(lock) }
        try? sweep(base, session: bootSession)
    }
    init(base: URL? = nil, bootSession: UUID? = HomebrewPackageStaging.bootSession) throws {
        guard let bootSession else {
            throw HomebrewPackageError.download("Macseed could not establish safe package retention for this session. Use the official download page.")
        }
        session = bootSession
        let base = base ?? Self.defaultBase
        if mkdir(base.path, 0o700) != 0 && errno != EEXIST { throw CocoaError(.fileWriteUnknown) }
        let lock = try Self.lockBase(base)
        defer { Darwin.close(lock) }
        try Self.sweep(base, session: bootSession)
        guard try Self.entries(base).count < Self.maximumEntries else {
            throw HomebrewPackageError.download("The package cache is full. Packages are kept safe for Installer until your Mac restarts. Reopen Macseed afterward to clear them, or use the official download page.")
        }
        var template = Array(base.appendingPathComponent("download-XXXXXX").path.utf8CString)
        guard let path = mkdtemp(&template) else { throw CocoaError(.fileWriteUnknown) }
        directory = URL(fileURLWithPath: String(cString: path), isDirectory: true)
        do {
            lease = try Self.openPrivate(directory.appendingPathComponent(".lease"), exclusive: true)
        } catch {
            try? FileManager.default.removeItem(at: directory); throw error
        }
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw CocoaError(.fileWriteUnknown)
        }
    }
    deinit { Darwin.close(lease) }
    func complete() throws {
        try FileManager.default.moveItem(at: partial, to: package)
        guard chmod(package.path, 0o400) == 0 else { throw CocoaError(.fileWriteNoPermission) }
    }
    func retainForInstaller() throws {
        try Self.markRetained(directory, session: session)
        retained = true
    }
    func remove() {
        guard !retained else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

struct HomebrewPublisher: Sendable {
    let identity: String
    let evidence: URL
    // Homebrew maintainers confirm this signer in discussion #5557 (2024-08-15/16).
    // Re-reviewed 2026-11-03. A rotated identity fails closed pending upstream review.
    static let reviewed = HomebrewPublisher(identity: "Developer ID Installer: Patrick Linnane (927JGANW46)",
        evidence: URL(string: "https://github.com/orgs/Homebrew/discussions/5557")!)
}

enum HomebrewPackageVerifier {
    static func hash(_ file: URL, size: Int64) throws -> String {
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw HomebrewPackageError.verification("The downloaded package is no longer readable.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_size == size, info.st_mode & 0o077 == 0 else {
            throw HomebrewPackageError.verification("The downloaded package has unexpected file properties or size.")
        }
        var digest = SHA256(), count: Int64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation(); count += Int64(chunk.count)
            guard count <= size else { throw HomebrewPackageError.verification("The package changed during verification.") }
            digest.update(data: chunk)
        }
        guard count == size else { throw HomebrewPackageError.verification("The package is incomplete.") }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    // pkgutil validates the package signature. Certificate fingerprints bind the
    // separately evaluated XAR chain to exactly that signing identity/chain.
    @discardableResult
    static func validateSignature(_ result: NativeHomebrewRead.Result, publisher: HomebrewPublisher?) throws -> [String] {
        let lines = result.output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let statuses = lines.filter { $0.hasPrefix("Status:") }
        guard result.complete, result.exitCode == 0,
              statuses == ["Status: signed by a certificate trusted by macOS"]
                || statuses == ["Status: signed by a developer certificate issued by Apple for distribution"] else {
            throw HomebrewPackageError.verification("macOS could not validate the package signature. Installer was not opened.")
        }
        guard let publisher else {
            throw HomebrewPackageError.verification("Trusted Homebrew publisher evidence is unavailable. Installer was not opened.")
        }
        guard lines.filter({ $0.hasPrefix("1. ") }) == ["1. " + publisher.identity] else {
            throw HomebrewPackageError.verification("The package was signed by an unexpected publisher. Installer was not opened.")
        }
        let pattern = #"SHA256 Fingerprint:\s*([A-Fa-f0-9]{2}(?:\s+[A-Fa-f0-9]{2}){31})(?=\s|$)"#
        let expression = try NSRegularExpression(pattern: pattern)
        let fingerprints = expression.matches(in: result.output, range: NSRange(result.output.startIndex..., in: result.output)).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: result.output) else { return nil }
            return result.output[range].filter { !$0.isWhitespace }.lowercased()
        }
        guard fingerprints.count == 3 else { throw certificateFailure }
        return fingerprints
    }

    enum AssessmentMode: Equatable { case enabled, disabled }
    static func assessmentMode(_ result: NativeHomebrewRead.Result) throws -> AssessmentMode {
        guard result.complete else { throw assessmentUnavailable }
        switch (result.exitCode, result.output.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case (0, "assessments enabled"): return .enabled
        case (1, "assessments disabled"): return .disabled
        default: throw assessmentUnavailable
        }
    }
    // Parse the structured assessment, including its pre-override verdict. Never
    // allow the independent path to erase an explicit rejection or assessment error.
    static func validateAssessment(_ result: NativeHomebrewRead.Result, mode: AssessmentMode,
                                   publisher: HomebrewPublisher) throws {
        guard result.complete, result.exitCode == 0,
              let data = result.output.data(using: .utf8), data.count <= 65536,
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let assessment = value as? [String: Any],
              let verdict = assessment["assessment:verdict"] as? NSNumber,
              CFGetTypeID(verdict) == CFBooleanGetTypeID(), verdict.boolValue,
              assessment["assessment:error"] == nil, assessment["assessment:cserror"] == nil,
              let authority = assessment["assessment:authority"] as? [String: Any] else { throw assessmentRejected }
        if let original = authority["assessment:authority:verdict"] {
            guard let boolean = original as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID(), boolean.boolValue else {
                throw assessmentRejected
            }
        }
        let override = authority["assessment:authority:override"]
        switch mode {
        case .enabled:
            guard override == nil, authority["assessment:authority:source"] as? String == "Notarized Developer ID",
                  assessment["assessment:originator"] as? String == publisher.identity else { throw assessmentRejected }
        case .disabled:
            guard override as? String == "security disabled" else { throw assessmentUnavailable }
            // A disabled assessment is not approval. Independent authentication
            // below remains mandatory, regardless of source/notarization strings.
            if let origin = assessment["assessment:originator"] {
                guard origin as? String == publisher.identity else { throw assessmentRejected }
            }
        }
    }
    static let assessmentUnavailable = HomebrewPackageError.verification(
        "The system security assessment status is unavailable or inconsistent. Installer was not opened. Use the official download page.")
    static let assessmentRejected = HomebrewPackageError.verification(
        "Gatekeeper rejected the package or returned an ambiguous assessment. Installer was not opened.")
    static let certificateFailure = HomebrewPackageError.verification(
        "The package signing certificate identity, validity or Apple trust could not be confirmed. Installer was not opened.")

    static func certificates(_ result: NativeHomebrewRead.Result, fingerprints: [String],
                             publisher: HomebrewPublisher, now: Date) throws -> [Data] {
        guard result.complete, result.exitCode == 0,
              let data = result.output.data(using: .utf8), data.count <= 65536,
              !result.output.contains("<!DOCTYPE"), !result.output.contains("<!ENTITY"),
              let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
              let signatures = try? document.nodes(forXPath: "/xar/toc/signature"), signatures.count == 1,
              let signature = signatures.first as? XMLElement, signature.attribute(forName: "style")?.stringValue == "RSA",
              let nodes = try? signature.nodes(forXPath: "./*[local-name()='KeyInfo']/*[local-name()='X509Data']/*[local-name()='X509Certificate']"),
              nodes.count == 3, fingerprints.count == 3 else { throw certificateFailure }
        return try nodes.enumerated().map { index, node in
            guard let encoded = node.stringValue,
                  let bytes = Data(base64Encoded: encoded.filter { !$0.isWhitespace }), bytes.count <= 16384,
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == fingerprints[index],
                  let certificate = SecCertificateCreateWithData(nil, bytes as CFData) else { throw certificateFailure }
            if index == 0 {
                var name: CFString?
                guard SecCertificateCopyCommonName(certificate, &name) == errSecSuccess,
                      name as String? == publisher.identity else { throw certificateFailure }
            }
            // Apple's Developer ID Installer policy validates signing purpose and
            // anchors, but permits historical certificates. Require current dates
            // explicitly; a timestamp cannot silently extend this policy.
            let keys = [kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter] as CFArray
            guard let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any],
                  let before = values[kSecOIDX509V1ValidityNotBefore as String] as? [String: Any],
                  let after = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
                  let start = before[kSecPropertyKeyValue as String] as? NSNumber,
                  let end = after[kSecPropertyKeyValue as String] as? NSNumber,
                  start.doubleValue <= now.timeIntervalSinceReferenceDate,
                  now.timeIntervalSinceReferenceDate < end.doubleValue else { throw certificateFailure }
            return bytes
        }
    }

    // System tool reads are injected only in tests; production always uses the
    // existing deadline/cancellation-aware, process-group-owning reader.
    typealias Read = @Sendable (String, [String], TimeInterval) -> NativeHomebrewRead.Result
    static let systemRead: Read = { executable, arguments, timeout in
        NativeHomebrewRead.run(executable, arguments: arguments, timeout: timeout,
            includeStandardError: true, cancelled: { Task.isCancelled })
    }
    // Apple SecPolicy.list / SecPolicyCreateDeveloperIDInstaller: Apple anchors,
    // 3-cert chain, Developer ID intermediate/Installer leaf markers and EKU,
    // strong keys and revocation. Unsupported policy fails closed on older hosts.
    static let developerIDInstallerPolicy = "1.2.840.113635.100.1.103"
    static func verify(_ plan: HomebrewDownloadPlan, file: URL, publisher: HomebrewPublisher? = .reviewed,
                       read: @escaping Read = systemRead, now: @escaping @Sendable () -> Date = { Date() }) async throws {
        let work = Task.detached(priority: .userInitiated) {
            guard try hash(file, size: plan.size) == plan.sha256 else {
                throw HomebrewPackageError.verification("The package SHA-256 does not match the official release. Installer was not opened.")
            }
            try Task.checkCancellation()
            let fingerprints = try validateSignature(read("/usr/sbin/pkgutil", ["--check-signature", file.path], 60), publisher: publisher)
            guard let publisher else { throw certificateFailure }
            try Task.checkCancellation()
            let mode = try assessmentMode(read("/usr/sbin/spctl", ["--status"], 10))
            let assessment = read("/usr/sbin/spctl", ["--assess", "--type", "install", "--raw", "--ignore-cache", "--no-cache", file.path], 60)
            try Task.checkCancellation()
            try validateAssessment(assessment, mode: mode, publisher: publisher)
            let toc = read("/usr/bin/xar", ["-f", file.path, "--dump-toc=/dev/stdout"], 30)
            let chain = try certificates(toc, fingerprints: fingerprints, publisher: publisher, now: now())
            try Task.checkCancellation()
            var certificateFiles: [URL] = []
            defer { certificateFiles.forEach { try? FileManager.default.removeItem(at: $0) } }
            for (index, bytes) in chain.enumerated() {
                let url = file.deletingLastPathComponent().appendingPathComponent("certificate-\(index).der")
                let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw certificateFailure }
                certificateFiles.append(url)
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                try handle.write(contentsOf: bytes)
            }
            let arguments = certificateFiles.flatMap { ["-c", $0.path] }
            let trust = read("/usr/bin/security", ["verify-cert", "-p", developerIDInstallerPolicy, "-N", "-R", "ocsp", "-R", "require", "-v"] + arguments, 60)
            try Task.checkCancellation()
            let trustLines = trust.output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            // verify-cert also exits 0 for user-explicit trust (Proceed = 1).
            // Require implicit system trust (Unspecified = 4), without exceptions,
            // and evidence that revocation was checked. Unknown formats fail closed.
            guard trust.complete, trust.exitCode == 0,
                  trustLines.filter({ $0.hasPrefix("TrustResultValue") }) == ["TrustResultValue = 4;"],
                  trustLines.filter({ $0.hasPrefix("TrustRevocationChecked") }) == ["TrustRevocationChecked = 1;"] else { throw certificateFailure }
            // Recheck mode and assessment after potentially slow trust/network
            // reads. A changed setting or a new rejection cannot inherit approval.
            guard try assessmentMode(read("/usr/sbin/spctl", ["--status"], 10)) == mode else { throw assessmentUnavailable }
            try validateAssessment(read("/usr/sbin/spctl", ["--assess", "--type", "install", "--raw", "--ignore-cache", "--no-cache", file.path], 60),
                                   mode: mode, publisher: publisher)
            try Task.checkCancellation()
            _ = try certificates(toc, fingerprints: fingerprints, publisher: publisher, now: now())
            guard try hash(file, size: plan.size) == plan.sha256 else {
                throw HomebrewPackageError.verification("The package changed during verification. Installer was not opened.")
            }
        }
        try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

}

struct HomebrewPackageService {
    var resolve: () async throws -> HomebrewDownloadPlan
    var download: (HomebrewDownloadPlan, URL, @escaping @Sendable (Int64) -> Void) async throws -> Void
    var verify: (HomebrewDownloadPlan, URL) async throws -> Void
    var openInstaller: @MainActor (URL) async throws -> Void
    static let live = Self(resolve: {
        try HomebrewDownloadPlan.parse(await HomebrewPackageTransfer().run())
    }, download: { plan, file, progress in
        _ = try await HomebrewPackageTransfer(plan: plan, target: file, progress: progress).run()
    }, verify: { plan, file in try await HomebrewPackageVerifier.verify(plan, file: file) }, openInstaller: { file in
        let application = URL(fileURLWithPath: "/System/Library/CoreServices/Installer.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await NSWorkspace.shared.open([file], withApplicationAt: application, configuration: configuration)
    })
}

enum HomebrewPackageState: Equatable {
    case idle, resolving, downloading(received: Int64, total: Int64), verifying, opening, opened, cancelled
    case failed(HomebrewPackageError)
    var title: String {
        switch self {
        case .idle: ""
        case .resolving: "Resolving download…"
        case .downloading: "Downloading Homebrew.pkg…"
        case .verifying: "Verifying package…"
        case .opening: "Opening Installer…"
        case .opened: "Installer opened"
        case .cancelled: "Cancelled"
        case .failed(.download): "Download failed"
        case .failed(.verification): "Verification failed"
        case .failed(.launch): "Installer could not open"
        }
    }
    var canCancel: Bool {
        switch self { case .resolving, .downloading, .verifying: true; default: false }
    }
    var offersFallback: Bool { if case .failed = self { return true }; return false }
}
