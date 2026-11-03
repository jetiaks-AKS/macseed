import AppKit
import CryptoKit
import Foundation
import SwiftUI

private final class PackageResponses: URLProtocol, @unchecked Sendable {
    enum Mode { case success, truncated, oversized, offline, httpError, stalled, redirect }
    static var mode = Mode.success
    static var payload = Data("package-fixture".utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.mode == .stalled { return }
        if Self.mode == .offline { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        if Self.mode == .redirect {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://example.com/Homebrew.pkg"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://example.com/Homebrew.pkg")!), redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.mode == .httpError ? 503 : 200,
            httpVersion: nil, headerFields: ["Content-Length": String(Self.payload.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let bytes = Self.mode == .truncated ? Self.payload.dropLast() : Self.mode == .oversized ? Self.payload + Data([0]) : Self.payload
        client?.urlProtocol(self, didLoad: bytes.prefix(3))
        client?.urlProtocol(self, didLoad: bytes.dropFirst(3))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private final class PackageProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    func append(_ value: Int64) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var snapshot: [Int64] { lock.lock(); defer { lock.unlock() }; return values }
}

@main struct HomebrewPackageTests {
    static let payload = Data("package-fixture".utf8)
    static var metadata: [String: Any] {
        ["id": 42, "tag_name": "1.2.3", "draft": false, "prerelease": false, "published_at": "2026-11-03T00:00:00Z",
         "url": "https://api.github.com/repos/Homebrew/brew/releases/42", "assets_url": "https://api.github.com/repos/Homebrew/brew/releases/42/assets",
         "html_url": "https://github.com/Homebrew/brew/releases/tag/1.2.3", "assets": [["id": 12, "name": "Homebrew.pkg", "state": "uploaded", "size": payload.count,
             "digest": "sha256:" + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
             "url": "https://api.github.com/repos/Homebrew/brew/releases/assets/12",
             "browser_download_url": "https://github.com/Homebrew/brew/releases/download/1.2.3/Homebrew.pkg"]]]
    }
    static func plan(_ input: [String: Any] = metadata) throws -> HomebrewDownloadPlan {
        try HomebrewDownloadPlan.parse(JSONSerialization.data(withJSONObject: input))
    }
    static func rejects(_ body: () throws -> Void) {
        do { try body(); preconditionFailure("Unsafe input was accepted") } catch { }
    }
    static var trustFixture: [String: Any] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/HomebrewPackageTrust.json")
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    }
    static var certificateBytes: [Data] { (trustFixture["certificates"] as! [String]).map { Data(base64Encoded: $0)! } }
    static var certificateTOC: String {
        "<?xml version=\"1.0\"?><xar><toc><signature style=\"RSA\"><KeyInfo xmlns=\"http://www.w3.org/2000/09/xmldsig#\"><X509Data>"
            + certificateBytes.map { "<X509Certificate>" + $0.base64EncodedString() + "</X509Certificate>" }.joined()
            + "</X509Data></KeyInfo></signature></toc></xar>"
    }
    static func signature(identity: String = HomebrewPublisher.reviewed.identity) -> NativeHomebrewRead.Result {
        let identities = [identity, "Developer ID Certification Authority", "Apple Root CA"]
        let chain = certificateBytes.enumerated().map { index, bytes in
            "\(index + 1). \(identities[index])\nSHA256 Fingerprint:\n"
                + SHA256.hash(data: bytes).map { String(format: "%02X", $0) }.joined(separator: " ") + "\n"
        }.joined()
        // Intentionally omit Notarization. Signature authentication must not
        // invent either a notary failure or success from a missing ticket/line.
        return .init(output: "Status: signed by a developer certificate issued by Apple for distribution\nCertificate Chain:\n" + chain, exitCode: 0, complete: true)
    }
    static func assessment(disabled: Bool = false, rejected: Bool = false, originalVerdict: Bool? = nil,
                           override: String? = nil, exitCode: Int32 = 0) -> NativeHomebrewRead.Result {
        var authority: [String: Any] = ["assessment:authority:source": "Notarized Developer ID"]
        if disabled { authority["assessment:authority:override"] = "security disabled" }
        if let override { authority["assessment:authority:override"] = override }
        if let originalVerdict { authority["assessment:authority:verdict"] = originalVerdict }
        var output: [String: Any] = ["assessment:verdict": !rejected, "assessment:authority": authority]
        if !disabled { output["assessment:originator"] = HomebrewPublisher.reviewed.identity }
        let data = try! PropertyListSerialization.data(fromPropertyList: output, format: .xml, options: 0)
        return .init(output: String(decoding: data, as: UTF8.self), exitCode: exitCode, complete: true)
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        if CommandLine.arguments.contains("--trust-only") { try await trustChecks(verifyInstalledHost: true); return }
        if let index = CommandLine.arguments.firstIndex(of: "--official-file") {
            guard CommandLine.arguments.indices.contains(index + 2) else { exit(2) }
            do { try await officialFile(URL(fileURLWithPath: CommandLine.arguments[index + 1]), metadata: URL(fileURLWithPath: CommandLine.arguments[index + 2])) }
            catch { print("BLOCKED: independent package authentication: \(error)"); exit(2) }
            return
        }
        if CommandLine.arguments.contains("--official-download") {
            do { try await officialDownload() } catch { print("BLOCKED: official evidence check: \(error)"); exit(2) }
            return
        }
        try await trustChecks()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macseed-package-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = try plan()
        precondition(valid.releaseID == 42 && valid.assetID == 12 && valid.size == payload.count)
        for (key, value) in [("draft", true as Any), ("prerelease", true), ("tag_name", "1.2.3-rc1"), ("url", "https://api.github.com/repos/other/brew/releases/42"), ("published_at", "bad")] {
            var input = metadata; input[key] = value; rejects { _ = try plan(input) }
        }
        for (key, value) in [("digest", "" as Any), ("name", "Homebrew-1.2.3.pkg"), ("size", 0), ("size", HomebrewDownloadPlan.maximumSize + 1), ("state", "new"),
                             ("browser_download_url", "http://github.com/Homebrew/brew/releases/download/1.2.3/Homebrew.pkg"),
                             ("browser_download_url", "https://github.com/other/brew/releases/download/1.2.3/Homebrew.pkg"),
                             ("url", "https://api.github.com/repos/other/brew/releases/assets/12")] {
            var input = metadata; var assets = input["assets"] as! [[String: Any]]; assets[0][key] = value; input["assets"] = assets
            rejects { _ = try plan(input) }
        }
        var missing = metadata; missing.removeValue(forKey: "draft"); rejects { _ = try plan(missing) }
        var duplicate = metadata; duplicate["assets"] = (metadata["assets"] as! [[String: Any]]) + (metadata["assets"] as! [[String: Any]])
        rejects { _ = try plan(duplicate) }; rejects { _ = try HomebrewDownloadPlan.parse(Data("{".utf8)) }
        for url in ["https://example.com/Homebrew.pkg", "http://release-assets.githubusercontent.com/github-production-release-asset/53238813/abcd", "https://github.com.evil.test/Homebrew.pkg",
                    "https://user@release-assets.githubusercontent.com/github-production-release-asset/53238813/abcd", "https://release-assets.githubusercontent.com/github-production-release-asset/1/abcd",
                    valid.url.absoluteString + "?redirect=evil"] { precondition(!valid.permitsDownloadURL(URL(string: url)!)) }
        precondition(valid.permitsDownloadURL(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/53238813/abc-def?token=fixture")!))
        print("PASS: official stable release/asset binding; malformed, missing, duplicate metadata and unsupported URLs fail closed")

        for mode in [PackageResponses.Mode.success, .truncated, .oversized, .offline, .httpError, .redirect] {
            PackageResponses.mode = mode
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PackageResponses.self]
            let staging = try HomebrewPackageStaging(base: root)
            defer { staging.remove() }
            let progress = PackageProgress()
            do {
                _ = try await HomebrewPackageTransfer(plan: valid, target: staging.partial, configuration: configuration, progress: { progress.append($0) }).run()
                precondition(mode == .success)
                try staging.complete()
                let downloaded = try Data(contentsOf: staging.package)
                precondition(downloaded == payload)
                precondition(progress.snapshot.last == valid.size && progress.snapshot == progress.snapshot.sorted())
                let digest = try HomebrewPackageVerifier.hash(staging.package, size: valid.size)
                precondition(digest == valid.sha256)
                do { try await HomebrewPackageVerifier.verify(valid, file: staging.package); preconditionFailure("Malformed pkg passed") } catch { }
            } catch { precondition(mode != .success, "Valid fixture failed: \(error)") }
        }
        PackageResponses.mode = .stalled
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PackageResponses.self]
        let cancelled = try HomebrewPackageStaging(base: root)
        let transfer = Task { try await HomebrewPackageTransfer(plan: valid, target: cancelled.partial, configuration: config).run() }
        try await Task.sleep(nanoseconds: 50_000_000); transfer.cancel()
        do { _ = try await transfer.value; preconditionFailure("Cancellation ignored") } catch is CancellationError { }
        cancelled.remove(); precondition(!FileManager.default.fileExists(atPath: cancelled.directory.path))
        do { _ = try await HomebrewPackageTransfer(configuration: config, duration: 0.05).run(); preconditionFailure("Deadline ignored") } catch { }
        print("PASS: real URLSession with injected responses: stream/progress, network/HTTP failure, truncation, excess bytes, hostile redirect, cancellation and deadline")

        try HomebrewPackageVerifier.validateSignature(signature(), publisher: .reviewed)
        try HomebrewPackageVerifier.validateAssessment(assessment(), mode: .enabled, publisher: .reviewed)
        rejects { try HomebrewPackageVerifier.validateSignature(.init(output: "unsigned", exitCode: 1, complete: true), publisher: .reviewed) }
        rejects { try HomebrewPackageVerifier.validateSignature(signature(identity: "Developer ID Installer: Other (ABCDEFGHIJ)"), publisher: .reviewed) }
        rejects { try HomebrewPackageVerifier.validateSignature(signature(), publisher: nil) }
        rejects { try HomebrewPackageVerifier.validateAssessment(assessment(exitCode: 3), mode: .enabled, publisher: .reviewed) }
        rejects { try HomebrewPackageVerifier.validateAssessment(assessment(disabled: true), mode: .enabled, publisher: .reviewed) }
        let mismatched = try HomebrewPackageStaging(base: root)
        try Data(repeating: 0, count: payload.count).write(to: mismatched.partial); try mismatched.complete()
        do {
            try await HomebrewPackageVerifier.verify(valid, file: mismatched.package)
            preconditionFailure("Wrong SHA passed")
        } catch HomebrewPackageError.verification(let message) { precondition(message.contains("SHA-256")) }
        mismatched.remove()
        print("PASS: digest mismatch, malformed/invalid signature, unexpected/missing publisher and rejected/overridden Gatekeeper block launch")

        let lifecycleRoot = root.appendingPathComponent("lifecycle")
        try FileManager.default.createDirectory(at: lifecycleRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try await lifecycleChecks(lifecycleRoot)
        try cacheChecks(root)

        let suite = "org.macseed.homebrew-test.package." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let host = HomebrewHost(architecture: .appleSilicon, majorVersion: 27, version: "27.2")
        var observation = HomebrewObservation.absent, resolutions = 0, launches = 0, terminal = 0
        var failDownload = true, failLaunch = false, pauseDownload = false, pauseVerification = false, appearDuringDownload = false
        var verificationFailure: HomebrewPackageError?
        var openedFile: URL?
        let service = HomebrewPackageService(resolve: { resolutions += 1; return valid }, download: { plan, file, progress in
            if failDownload { throw HomebrewPackageError.download("Injected network failure") }
            progress(3)
            while pauseDownload { try await Task.sleep(nanoseconds: 10_000_000) }
            try payload.write(to: file, options: .withoutOverwriting)
            progress(plan.size)
            if appearDuringDownload { observation = .usable }
        }, verify: { _, _ in
            while pauseVerification { try await Task.sleep(nanoseconds: 10_000_000) }
            if let verificationFailure { throw verificationFailure }
        }, openInstaller: { file in
            launches += 1; openedFile = file
            if failLaunch { throw CocoaError(.fileReadUnknown) }
        })
        func model() async -> HomebrewSetupModel {
            let model = HomebrewSetupModel(host: host, preferences: preferences, detect: { observation },
                openTerminal: { terminal += 1; return true }, packageService: service, packageStagingBase: root)
            await model.prepareLaunch(); return model
        }
        let retry = await model(); retry.installPackage(); retry.installPackage(); await retry.waitForPackageDownload()
        precondition(resolutions == 1 && launches == 0 && retry.packageState == .failed(.download("Injected network failure")))
        precondition((try? FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("download-") }.isEmpty) == true)
        failDownload = false; pauseDownload = true
        retry.installPackage()
        while retry.packageState == .resolving { await Task.yield() }
        precondition(retry.packageState.title == "Downloading Homebrew.pkg…")
        retry.selectMethod(.terminal); await retry.waitForPackageDownload()
        precondition(retry.packageState == .cancelled && retry.installationMethod == .terminal)
        precondition((try? FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("download-") }.isEmpty) == true)
        await retry.launchTerminal(); precondition(terminal == 1 && launches == 0)
        pauseDownload = false; pauseVerification = true
        retry.installPackage()
        while retry.packageState != .verifying { await Task.yield() }
        var responsive = false
        Task { responsive = true }
        await Task.yield(); precondition(responsive, "Verification must release MainActor")
        retry.cancelPackageDownload(); await retry.waitForPackageDownload(); precondition(launches == 0)
        pauseVerification = false
        verificationFailure = .verification("Injected untrusted package")
        retry.installPackage(); await retry.waitForPackageDownload(); precondition(launches == 0 && retry.packageState.offersFallback)
        verificationFailure = nil
        retry.installPackage(); await retry.waitForPackageDownload()
        precondition(launches == 1 && retry.packageState == .opened && retry.observation == .absent)
        precondition(FileManager.default.fileExists(atPath: openedFile!.path))
        _ = retry.finishSetup(notNow: true)
        precondition(FileManager.default.fileExists(atPath: openedFile!.path), "Closing setup must retain the Installer's package")
        await retry.checkAgain(); precondition(retry.observation == .absent && retry.canDownloadPackage)
        observation = .usable; await retry.checkAgain(); precondition(retry.observation == .usable)
        retry.installPackage(); await retry.waitForPackageDownload(); precondition(launches == 1)
        observation = .absent; failLaunch = true
        let failedLaunch = await model(); failedLaunch.installPackage(); await failedLaunch.waitForPackageDownload()
        if case .failed(.launch) = failedLaunch.packageState { } else { preconditionFailure("Launch failure misclassified") }
        failLaunch = false; appearDuringDownload = true
        let changed = await model(); changed.installPackage(); await changed.waitForPackageDownload(); precondition(launches == 2)
        print("PASS: model retry, duplicate rejection, responsive verification, cancel/switch to independent Terminal, verification refusal, simulated launch/failure, retained handoff, fresh absence gate and Check Again only availability")
    }


    private final class TrustReads: @unchecked Sendable {
        let disabled: Bool
        var rejected = false, invalidSigner = false, invalidSignature = false, unknown = false, trustExit: Int32 = 0
        var originalRejection = false, incompleteTrust = false, flipStatus = false, explicitTrust = false, missingTrustEvidence = false
        var toc = HomebrewPackageTests.certificateTOC
        var holdTrust: DispatchSemaphore?
        private let lock = NSLock()
        private var commands: [String] = []
        init(disabled: Bool) { self.disabled = disabled }
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return commands }
        func run(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> NativeHomebrewRead.Result {
            lock.lock(); commands.append(executable + " " + arguments.prefix(2).joined(separator: " "))
            let statusCount = commands.filter { $0 == "/usr/sbin/spctl --status" }.count
            lock.unlock()
            if executable == "/usr/sbin/pkgutil" {
                if invalidSignature { return .init(output: "Status: invalid signature", exitCode: 1, complete: true) }
                return HomebrewPackageTests.signature(identity: invalidSigner ? "Developer ID Installer: Other (ABCDEFGHIJ)" : HomebrewPublisher.reviewed.identity)
            }
            if executable == "/usr/sbin/spctl" {
                if arguments == ["--status"] {
                    if unknown { return .init(output: "security status unavailable", exitCode: 0, complete: true) }
                    let isDisabled = flipStatus && statusCount > 1 ? !disabled : disabled
                    return .init(output: isDisabled ? "assessments disabled\n" : "assessments enabled\n", exitCode: isDisabled ? 1 : 0, complete: true)
                }
                precondition(arguments.contains("--raw") && arguments.contains("--ignore-cache") && arguments.contains("--no-cache"))
                return HomebrewPackageTests.assessment(disabled: disabled, rejected: rejected,
                    originalVerdict: originalRejection ? false : nil, exitCode: rejected ? 3 : 0)
            }
            if executable == "/usr/bin/xar" { return .init(output: toc, exitCode: 0, complete: true) }
            precondition(executable == "/usr/bin/security")
            precondition(arguments.prefix(9) == ["verify-cert", "-p", HomebrewPackageVerifier.developerIDInstallerPolicy, "-N", "-R", "ocsp", "-R", "require", "-v"])
            if let holdTrust { precondition(holdTrust.wait(timeout: .now() + 3) == .success) }
            let evidence = missingTrustEvidence ? "" : "\nTrustResultValue = \(explicitTrust ? 1 : 4);\nTrustRevocationChecked = 1;\n"
            return .init(output: (trustExit == 0 ? "...certificate verification successful." : "certificate trust failed") + evidence, exitCode: trustExit, complete: !incompleteTrust)
        }
    }
    @MainActor static func trustChecks(verifyInstalledHost: Bool = false) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macseed-package-trust-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "org.macseed.homebrew-test.trust." + UUID().uuidString, now = ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z")!
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let host = HomebrewHost(architecture: .appleSilicon, majorVersion: 27, version: "27.2")
        let before = verifyInstalledHost ? await HomebrewSetupProbe.observe() : .usable
        precondition(before.state == .usable, "This focused host-preservation gate requires the existing healthy Homebrew")
        func installedSnapshot() throws -> [String: String] {
            var result: [String: String] = [:]
            for prefix in ["/opt/homebrew", "/usr/local/Homebrew"] {
                let brew = URL(fileURLWithPath: prefix + "/bin/brew")
                if FileManager.default.fileExists(atPath: brew.path) {
                    result[brew.path] = SHA256.hash(data: try Data(contentsOf: brew)).map { String(format: "%02x", $0) }.joined()
                }
                for directory in ["Cellar", "Caskroom"] {
                    let path = prefix + "/" + directory
                    if let names = try? FileManager.default.contentsOfDirectory(atPath: path) {
                        for name in names.sorted() {
                            result[path + "/" + name] = (try? FileManager.default.contentsOfDirectory(atPath: path + "/" + name).sorted().joined(separator: "\n")) ?? "unreadable"
                        }
                    }
                }
            }
            precondition(!result.isEmpty); return result
        }
        let installedBefore = verifyInstalledHost ? try installedSnapshot() : [:]
        for number in 1...6 {
            let reads = TrustReads(disabled: number >= 3)
            reads.rejected = number == 2; reads.invalidSigner = number == 4; reads.unknown = number == 6
            var launches = 0
            let model = HomebrewSetupModel(host: host, preferences: preferences, detect: { .absent },
                packageService: .init(resolve: { try plan() }, download: { _, file, _ in
                    try (number == 5 ? Data(repeating: 0, count: payload.count) : payload).write(to: file, options: .withoutOverwriting)
                }, verify: { plan, file in
                    try await HomebrewPackageVerifier.verify(plan, file: file, read: { reads.run($0, $1, $2) }, now: { now })
                }, openInstaller: { _ in launches += 1 }), packageStagingBase: root.appendingPathComponent("case-\(number)"))
            await model.check(); model.installPackage(); await model.waitForPackageDownload()
            let allowed = number == 1 || number == 3
            precondition(launches == (allowed ? 1 : 0))
            if allowed { precondition(model.packageState == .opened) }
            else { precondition(model.packageState.offersFallback) }
            if number == 5 { precondition(reads.calls.isEmpty, "Checksum failure must precede system assessment") }
            if allowed {
                precondition(reads.calls.filter { $0.hasPrefix("/usr/bin/security") }.count == 1)
                precondition(reads.calls.filter { $0 == "/usr/sbin/spctl --status" }.count == 2)
            }
            print("PASS trust #\(number): " + ["enabled + accepted", "enabled + rejected", "disabled + independently authenticated (no notarization line)", "disabled + invalid signer", "disabled + checksum mismatch", "unknown assessment status"][number - 1]
                  + (allowed ? "; one simulated handoff" : "; blocked, zero handoffs"))
        }
        let cancellation = TrustReads(disabled: true), gate = DispatchSemaphore(value: 0)
        cancellation.holdTrust = gate
        var launches = 0
        let cancelled = HomebrewSetupModel(host: host, preferences: preferences, detect: { .absent },
            packageService: .init(resolve: { try plan() }, download: { _, file, _ in try payload.write(to: file, options: .withoutOverwriting) },
                verify: { plan, file in try await HomebrewPackageVerifier.verify(plan, file: file, read: { cancellation.run($0, $1, $2) }, now: { now }) },
                openInstaller: { _ in launches += 1 }), packageStagingBase: root.appendingPathComponent("cancel"))
        await cancelled.check(); cancelled.installPackage()
        try await eventually("independent certificate verification started") { cancellation.calls.contains { $0.hasPrefix("/usr/bin/security") } }
        cancelled.cancelPackageDownload(); gate.signal(); await cancelled.waitForPackageDownload()
        precondition(cancelled.packageState == .cancelled && launches == 0)
        print("PASS trust #7: cancellation before handoff, including late successful certificate evaluation; zero handoffs")
        let healthy = HomebrewSetupModel(host: host, preferences: preferences, detect: { .usable }, packageService: .init(
            resolve: { preconditionFailure("Existing Homebrew must block package acquisition") }, download: { _, _, _ in preconditionFailure() },
            verify: { _, _ in preconditionFailure() }, openInstaller: { _ in preconditionFailure() }), packageStagingBase: root.appendingPathComponent("healthy"))
        await healthy.check(); healthy.installPackage(); await healthy.waitForPackageDownload()
        let after = verifyInstalledHost ? await HomebrewSetupProbe.observe() : .usable
        let installedAfter = verifyInstalledHost ? try installedSnapshot() : [:]
        precondition(after == before && installedAfter == installedBefore && !healthy.canDownloadPackage)
        print(verifyInstalledHost
            ? "PASS trust #8: existing real Homebrew remains usable; brew bytes and Cellar/Caskroom versions unchanged; healthy model blocks acquisition"
            : "PASS trust #8: healthy injected Homebrew blocks acquisition; real host preservation is opt-in --trust-only")

        for failure in ["invalid-signature", "explicit-disabled-rejection", "hidden-original-rejection", "uncertain-chain", "incomplete-chain", "user-trust-override", "missing-trust-evidence", "mode-changed", "expired", "expires-during-verification", "not-yet-valid", "malformed-toc", "substituted-certificate"] {
            let stage = try HomebrewPackageStaging(base: root.appendingPathComponent("negative"))
            defer { stage.remove() }
            try payload.write(to: stage.partial); try stage.complete()
            let reads = TrustReads(disabled: true)
            reads.invalidSignature = failure == "invalid-signature"
            reads.rejected = failure == "explicit-disabled-rejection"
            reads.originalRejection = failure == "hidden-original-rejection"
            reads.trustExit = failure == "uncertain-chain" ? 1 : 0
            reads.incompleteTrust = failure == "incomplete-chain"
            reads.explicitTrust = failure == "user-trust-override"
            reads.missingTrustEvidence = failure == "missing-trust-evidence"
            reads.flipStatus = failure == "mode-changed"
            if failure == "malformed-toc" { reads.toc = "<!DOCTYPE xar [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><xar>&x;</xar>" }
            if failure == "substituted-certificate" { reads.toc = certificateTOC.replacingOccurrences(of: certificateBytes[0].base64EncodedString(), with: certificateBytes[1].base64EncodedString()) }
            let date = failure == "expired" ? Date(timeIntervalSince1970: 2_100_000_000) : failure == "not-yet-valid" ? Date(timeIntervalSince1970: 1_600_000_000) : now
            do {
                try await HomebrewPackageVerifier.verify(plan(), file: stage.package, read: { reads.run($0, $1, $2) }, now: {
                    failure == "expires-during-verification" && reads.calls.contains(where: { $0.hasPrefix("/usr/bin/security") })
                        ? Date(timeIntervalSince1970: 2_100_000_000) : date
                })
                preconditionFailure("Accepted " + failure)
            } catch let error as HomebrewPackageError { precondition(error.message.contains("Installer was not opened")) }
        }
        for status in [
            NativeHomebrewRead.Result(output: "assessments disabled", exitCode: 0, complete: true),
            .init(output: "assessments enabled", exitCode: 1, complete: true),
            .init(output: "assessments enabled", exitCode: 0, complete: false)
        ] { rejects { _ = try HomebrewPackageVerifier.assessmentMode(status) } }
        rejects { try HomebrewPackageVerifier.validateAssessment(assessment(disabled: true), mode: .enabled, publisher: .reviewed) }
        rejects { try HomebrewPackageVerifier.validateAssessment(assessment(disabled: true, override: "user override"), mode: .disabled, publisher: .reviewed) }
        let partial = assessment()
        rejects { try HomebrewPackageVerifier.validateAssessment(.init(output: partial.output, exitCode: 0, complete: false), mode: .enabled, publisher: .reviewed) }
        print("PASS trust negatives: invalid signature, explicit/overridden rejection, uncertain/incomplete/overridden trust, mode change, expired/future certificates, malformed XML, certificate substitution and inconsistent/incomplete assessment results")
    }

    static func officialFile(_ file: URL, metadata: URL) async throws {
        let input: [String: Any] = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as! [String: Any]
        let plan = try HomebrewDownloadPlan.parse(JSONSerialization.data(withJSONObject: input))
        try await HomebrewPackageVerifier.verify(plan, file: file)
        print("PASS: full production authentication of official Homebrew \(plan.version), SHA-256 \(plan.sha256). Gatekeeper state checked twice; signature-bound certificates, Apple Developer ID Installer trust, current validity and positive revocation verified. Installer NOT opened.")
    }

    @MainActor final class Suspension {
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func finish() { continuation?.resume(); continuation = nil }
    }
    @MainActor static func eventually(_ description: String, _ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !predicate() {
            precondition(ProcessInfo.processInfo.systemUptime < deadline, "Timed out: " + description)
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    @MainActor static func lifecycleChecks(_ root: URL) async throws {
        _ = NSApplication.shared
        let suite = "org.macseed.homebrew-test.lifecycle." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let host = HomebrewHost(architecture: .appleSilicon, majorVersion: 27, version: "27.2")
        // Deliberately non-cooperative dependencies complete AFTER cancellation.
        // This proves the model's handoff gate, not just URLSession's cooperation.
        for scenario in ["download-cancel", "download-not-now", "download-close", "download-terminal",
                         "download-check-again", "verification-cancel", "verification-not-now",
                         "manual-dismiss", "late-error", "late-progress"] {
            let base = root.appendingPathComponent(scenario)
            let gate = Suspension()
            var downloads = 0, resolutions = 0, verifications = 0, launches = 0
            var file: URL?
            var progressCallback: (@Sendable (Int64) -> Void)?
            let verifying = scenario.hasPrefix("verification")
            let service = HomebrewPackageService(resolve: { resolutions += 1; return try plan() }, download: { plan, target, progress in
                downloads += 1; file = target; progressCallback = progress
                try payload.write(to: target, options: .withoutOverwriting)
                progress(3)
                if !verifying { await gate.wait() }
                progress(plan.size)
                if scenario == "late-error" { throw HomebrewPackageError.download("Late network failure") }
            }, verify: { _, _ in
                verifications += 1
                if verifying { await gate.wait() }
            }, openInstaller: { _ in launches += 1 })
            let model = HomebrewSetupModel(host: host, preferences: preferences, detect: { .absent },
                packageService: service, packageStagingBase: base)
            let manual = scenario == "manual-dismiss"
            if manual { await model.check(); model.beginSetup() } else { await model.prepareLaunch() }
            let reminder = model.remindersEnabled
            var window: NSWindow?
            if scenario == "download-close" || manual {
                let native = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
                native.isReleasedWhenClosed = false
                native.contentView = NSHostingView(rootView: HomebrewSetupWindow(model: model))
                native.makeKeyAndOrderFront(nil); window = native
                try await eventually("setup window connection") { native.identifier?.rawValue == "homebrew-setup" }
            }
            model.installPackage()
            for _ in 0..<20 { model.installPackage() }
            try await eventually(scenario + " suspended") { gate.continuation != nil }
            precondition(resolutions == 1 && downloads == 1 && launches == 0)
            precondition(model.packageState.canCancel)
            switch scenario {
            case "download-not-now", "verification-not-now":
                precondition(model.finishSetup(notNow: true))
            case "download-close", "manual-dismiss":
                window!.performClose(nil)
                try await eventually("native close cancels") { model.packageState == .cancelled }
            case "download-terminal": model.selectMethod(.terminal)
            case "download-check-again": await model.checkAgain()
            default: model.cancelPackageDownload()
            }
            precondition(model.packageState == .cancelled)
            if manual { precondition(model.remindersEnabled == reminder && !model.startupPending) }
            if verifying { precondition(FileManager.default.fileExists(atPath: file!.deletingLastPathComponent().appendingPathComponent("Homebrew.pkg").path)) }
            else { precondition(FileManager.default.fileExists(atPath: file!.path)) }
            // Draining work still owns staging; rapid retry must not overlap it.
            for _ in 0..<20 { model.installPackage() }
            progressCallback?(9)
            try await Task.sleep(nanoseconds: 20_000_000)
            precondition(model.packageState == .cancelled && downloads == 1)
            gate.finish(); await model.waitForPackageDownload()
            precondition(model.packageState == .cancelled && launches == 0)
            precondition(verifications == (verifying ? 1 : 0))
            precondition(!FileManager.default.fileExists(atPath: file!.deletingLastPathComponent().path))
            if scenario == "download-terminal" { precondition(model.installationMethod == .terminal) }
            print("PASS lifecycle: " + scenario + "; repeated clicks and late completion cannot launch Installer")
        }
        let handoffBase = root.appendingPathComponent("handoff"), handoff = Suspension()
        var handoffs = 0, handedFile: URL?
        let opening = HomebrewSetupModel(host: host, preferences: preferences, detect: { .absent },
            packageService: .init(resolve: { try plan() }, download: { _, file, _ in
                try payload.write(to: file, options: .withoutOverwriting)
            }, verify: { _, _ in }, openInstaller: { file in
                handoffs += 1; handedFile = file; await handoff.wait()
                throw CocoaError(.fileReadUnknown) // Launch outcome is uncertain.
            }), packageStagingBase: handoffBase)
        await opening.prepareLaunch(); opening.installPackage()
        try await eventually("external handoff started") { handoff.continuation != nil }
        precondition(opening.packageState == .opening && !opening.packageState.canCancel)
        _ = opening.finishSetup(notNow: true)
        for _ in 0..<20 { opening.installPackage() }
        HomebrewPackageStaging.cleanup(base: handoffBase)
        precondition(handoffs == 1 && FileManager.default.fileExists(atPath: handedFile!.path))
        handoff.finish(); await opening.waitForPackageDownload()
        HomebrewPackageStaging.cleanup(base: handoffBase)
        if case .failed(.launch) = opening.packageState {} else { preconditionFailure("Uncertain handoff misclassified") }
        precondition(FileManager.default.fileExists(atPath: handedFile!.path))
        print("PASS lifecycle: committed handoff survives dismissal, cache sweep and late launch error; no duplicate launch")

        // The same bounded subprocess reader used by verification must respond to
        // cancellation rather than waiting for its command's full timeout.
        let started = ProcessInfo.processInfo.systemUptime
        let child = Task.detached {
            NativeHomebrewRead.run("/bin/sleep", arguments: ["10"], timeout: 12, cancelled: { Task.isCancelled })
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        child.cancel()
        let result = await child.value
        precondition(!result.complete && ProcessInfo.processInfo.systemUptime - started < 2)
        print("PASS lifecycle: real verification subprocess reader terminates promptly on cancellation")
    }

    static func cacheChecks(_ root: URL) throws {
        let base = root.appendingPathComponent("cache-lifecycle"), session = UUID(), nextSession = UUID()
        var active: HomebrewPackageStaging? = try HomebrewPackageStaging(base: base, bootSession: session)
        let activeDirectory = active!.directory
        try payload.write(to: active!.partial)
        HomebrewPackageStaging.cleanup(base: base, bootSession: session)
        precondition(FileManager.default.fileExists(atPath: activeDirectory.path), "An active lease must survive cleanup")
        active = nil // Simulate app death during acquisition (flock is released).
        HomebrewPackageStaging.cleanup(base: base, bootSession: session)
        precondition(!FileManager.default.fileExists(atPath: activeDirectory.path))
        var retainedFiles: [URL] = []
        for _ in 0..<HomebrewPackageStaging.maximumEntries {
            let stage = try HomebrewPackageStaging(base: base, bootSession: session)
            try payload.write(to: stage.partial); try stage.complete(); try stage.retainForInstaller()
            stage.remove() // Even accidental cleanup after handoff must be harmless.
            retainedFiles.append(stage.package)
        }
        HomebrewPackageStaging.cleanup(base: base, bootSession: session)
        precondition(retainedFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        rejects { _ = try HomebrewPackageStaging(base: base, bootSession: session) }
        HomebrewPackageStaging.cleanup(base: base, bootSession: nil)
        precondition(retainedFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        HomebrewPackageStaging.cleanup(base: base, bootSession: nextSession)
        precondition(retainedFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let legacy = base.appendingPathComponent("download-legacy")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try payload.write(to: legacy.appendingPathComponent("Homebrew.pkg"))
        HomebrewPackageStaging.cleanup(base: base, bootSession: session)
        HomebrewPackageStaging.cleanup(base: base, bootSession: session)
        precondition(FileManager.default.fileExists(atPath: legacy.path), "Legacy handoff must survive this boot")
        HomebrewPackageStaging.cleanup(base: base, bootSession: nextSession)
        precondition(!FileManager.default.fileExists(atPath: legacy.path))
        let outside = root.appendingPathComponent("keep-user-file")
        try payload.write(to: outside)
        let suspicious = base.appendingPathComponent("download-unsafe")
        try FileManager.default.createDirectory(at: suspicious, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: suspicious.appendingPathComponent("Homebrew.pkg"), withDestinationURL: outside)
        HomebrewPackageStaging.cleanup(base: base, bootSession: nextSession)
        let preserved = try Data(contentsOf: outside)
        precondition(preserved == payload)
        precondition(FileManager.default.fileExists(atPath: suspicious.path))
        print("PASS cache: active lease protected; abandoned work removed; handoff retained across closure/failure; quota bounds accumulation; next-boot cleanup; legacy adoption; unknown boot and symlinks fail closed")
    }

    @MainActor static func officialDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("macseed-official-pkg-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try await HomebrewPackageService.live.resolve()
        let stage = try HomebrewPackageStaging(base: root)
        print("Official immutable plan: release \(plan.releaseID), version \(plan.version), asset \(plan.assetID), size \(plan.size), SHA-256 \(plan.sha256)")
        try await HomebrewPackageService.live.download(plan, stage.partial, { _ in })
        try stage.complete()
        let digest = try HomebrewPackageVerifier.hash(stage.package, size: plan.size)
        precondition(digest == plan.sha256)
        print("PASS: production URLSession official metadata/download, restricted redirect, size and SHA-256")
        for (name, executable, arguments) in [
            ("signature", "/usr/sbin/pkgutil", ["--check-signature", stage.package.path]),
            ("assessment", "/usr/sbin/spctl", ["--assess", "--type", "install", "--verbose=4", "--ignore-cache", "--no-cache", stage.package.path]),
            ("independent notarization", "/usr/bin/xcrun", ["stapler", "validate", stage.package.path])
        ] {
            let evidence = await Task.detached {
                NativeHomebrewRead.run(executable, arguments: arguments, timeout: 90, includeStandardError: true)
            }.value
            print("Evidence: \(name), complete=\(evidence.complete), exit=\(evidence.exitCode)\n\(evidence.output)")
        }
        do {
            try await HomebrewPackageService.live.verify(plan, stage.package)
            print("PASS: real package authentication under the observed security policy; disabled assessments are not Gatekeeper approval. Installer launch deliberately NOT exercised.")
        } catch {
            print("BLOCKED: real package verification: \(error). Installer was NOT opened.")
            throw error
        }
    }
}
