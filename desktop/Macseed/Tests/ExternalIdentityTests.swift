import AppKit
import Foundation

@main struct ExternalIdentityTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        // Preserve the caller's canonical path: Foundation standardization turns
        // /private/tmp into the /tmp alias rejected by bundled-tool validation.
        let repository = URL(fileURLWithPath: CommandLine.arguments[1])
        let python = URL(fileURLWithPath: CommandLine.arguments[2])
        let root = URL(fileURLWithPath: "/private/tmp/macseed-external-native-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let app = repository.appendingPathComponent("desktop/Macseed/build/Debug/Macseed.app")
        let legacyOnly = CommandLine.arguments.contains("--legacy-only")
        let keySecret = Data(("fixture-key-" + UUID().uuidString).utf8), bundleSecret = Data(("fixture-bundle-" + UUID().uuidString).utf8)
        let setup = Process(), input = Pipe()
        setup.executableURL = python
        setup.arguments = ["-B", repository.appendingPathComponent("desktop/Macseed/Tests/SecureRestoreFixture.py").path,
                           repository.path, root.path, app.appendingPathComponent("Contents/Helpers/age").path, "--capture-source", "--passphrase-source"]
        setup.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin", "TMPDIR": root.path, "PYTHONDONTWRITEBYTECODE": "1"]
        setup.standardInput = input; setup.standardOutput = FileHandle.nullDevice; setup.standardError = FileHandle.nullDevice
        try setup.run(); try input.fileHandleForWriting.write(contentsOf: keySecret + Data([10]) + bundleSecret)
        try input.fileHandleForWriting.close(); setup.waitUntilExit()
        precondition(setup.terminationStatus == 0)
        let core = root.appendingPathComponent("core"), source = root.appendingPathComponent("home"), target = root.appendingPathComponent("different-target-home"), bin = root.appendingPathComponent("bin")
        try fm.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try fm.removeItem(at: bin.appendingPathComponent("age")); try fm.removeItem(at: bin.appendingPathComponent("brew"))
        func location(_ home: URL) -> CoreLocation { .init(root: core, python: python, home: home, temporaryBase: root, toolDirectories: [bin], applicationBundle: app) }
        let logs = OperationLogStore(directory: root.appendingPathComponent("operations")), runtime = CoreRuntime(operationLogs: nil)
        // Use a separate log-enabled runtime for the entire new production flow.
        let owned = CoreRuntime(operationLogs: logs)
        let capture = CaptureModel(runtime: owned, location: location(source)), restore = RestoreModel(runtime: owned, location: location(target))
        let ssh = target.appendingPathComponent(".ssh")
        var identities: [CoreCaptureSecureInventory.Identity] = []
        var sourceForName: [String: URL] = [:]
        func snapshot(_ base: URL) throws -> [String: Data] {
            var result: [String: Data] = [:]
            for url in [base] + ((fm.enumerator(at: base, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []) {
                var info = stat(); precondition(lstat(url.path, &info) == 0)
                var data = Data("\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_uid):\(info.st_nlink):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)".utf8)
                if info.st_mode & S_IFMT == S_IFREG { data += try Data(contentsOf: url) }
                result[url.path] = data
            }
            return result
        }
        func staging() throws -> Set<String> {
            let prefixes = ["ssh-migrate-", "macseed-evidence-", "macseed-capture-", "macseed-restore-", "macseed-secure-", "macseed-operation-"]
            return Set(try [root, URL(fileURLWithPath: "/private/tmp")].flatMap { base in
                try fm.contentsOfDirectory(atPath: base.path).filter { name in prefixes.contains { name.hasPrefix($0) } }.map { base.path + "/" + $0 }
            })
        }
        func interact(cancel: CoreSecureChallenge.Kind? = nil, interrupt: Bool = false, changed: (() throws -> Void)? = nil) async throws -> [CoreSecureChallenge] {
            let end = Date().addingTimeInterval(120)
            var challenges: [CoreSecureChallenge] = [], seen = Set<String>()
            while capture.busy || restore.busy || owned.isActive {
                precondition(Date() < end, "Focused secure operation timed out")
                if let challenge = owned.secureChallenge, seen.insert(challenge.challengeID).inserted {
                    challenges.append(challenge)
                    var response: CoreSecureResponse = .secret(bundleSecret)
                    if challenge.kind == .sshKeyUnlock {
                        let identity = challenge.identity!
                        let expected = identities.first { $0.label == identity.name }!
                        precondition(identity.keyType == expected.keyType && identity.fingerprint == expected.fingerprint)
                        precondition(identity.position == identities.map(\.label).sorted().firstIndex(of: identity.name)! + 1 && identity.total == identities.count)
                        response = .secret(keySecret)
                    } else if challenge.kind == .importConfirmation { response = .confirmImport }
                    if challenge.kind == .bundleEncrypt { try changed?() }
                    if cancel == challenge.kind {
                        if interrupt { owned.cancel(); continue }
                        response = .cancel
                    }
                    precondition(owned.respond(to: challenge, with: response))
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            await capture.waitForCompletion(); await restore.waitForCompletion()
            precondition(owned.secureChallenge == nil)
            return challenges
        }
        func scan() async {
            capture.scan(); await capture.waitForCompletion(); precondition(capture.state == .review)
            for category in capture.categories where category.selectable { capture.selectCategory(category.id, included: false) }
        }
        func prepare(_ name: String) async -> URL {
            let bundle = root.appendingPathComponent(name + ".mbt")
            identities = capture.secureInventory.items.filter { capture.selectedSecureIdentities.contains($0.id) }
            capture.prepare(destination: bundle); await capture.waitForCompletion()
            if capture.state != .confirmation { print("Preparation reason:", capture.failure?.technicalReason ?? "none") }
            precondition(capture.state == .confirmation)
            return bundle
        }
        func publish(_ name: String, changed: (() throws -> Void)? = nil) async throws -> URL {
            let bundle = await prepare(name), before = try staging()
            capture.create(); _ = try await interact(changed: changed)
            precondition(try! staging() == before)
            if changed == nil {
                if capture.state != .result { print("Publication reason:",capture.failure?.technicalReason ?? "none") }
                precondition(capture.state == .result && capture.publicationEvidence == .occurred)
            } else { precondition(capture.state == .failed && !fm.fileExists(atPath: bundle.path)) }
            return bundle
        }
        func choose(_ bundle: URL, secure: Bool = true) async {
            restore.choose(bundle); await restore.waitForCompletion(); precondition(restore.state == .review && !restore.includeSecure)
            for area in restore.eligibleAreas { restore.selectArea(area.id, included: false) }
            restore.selectSecureTransfer(secure)
        }
        func preview(_ expected: CoreSecureComparison.Decision, _ bundle: URL) async throws {
            await choose(bundle)
            let before = try snapshot(target), temporary = try staging()
            restore.refreshPreview(); let challenges = try await interact()
            if restore.state != .preview { print("Preview reason:", restore.technicalReason ?? "none") }
            precondition(restore.state == .preview && restore.preparation?.secureComparison?.decision == expected)
            precondition(challenges.map(\.kind) == [.bundleUnlock])
            precondition(try! snapshot(target) == before && staging() == temporary)
            let tasks = RestoreTaskPresentation(preview: restore.preview!, plan: restore.preparation!)
            let secure = tasks.domains.first { $0.id == CoreRestorePreparation.secureDomain }!
            let counts = RestorePreviewMetrics.counts([secure])
            precondition(counts.matching == (expected == .allMatch ? 1 : 0) && counts.changes == (expected == .importRequired ? 1 : 0) && counts.attention == (expected == .conflict ? 1 : 0))
            precondition(restore.canRebuild == (expected == .importRequired))
        }
        func execute(cancel: CoreSecureChallenge.Kind? = nil, interrupt: Bool = false) async throws {
            let before = try snapshot(target), temporary = try staging()
            restore.requestRebuild(); restore.confirmRebuild(); _ = try await interact(cancel: cancel, interrupt: interrupt)
            precondition(restore.state == .result)
            let evidence = CoreSecureRestoreEvidence(events: restore.categoryPresentationEvents)
            if cancel == nil {
                precondition(evidence.verified && restore.executionResult?.outcome == .clean)
                for identity in identities { for suffix in ["", ".pub"] {
                    precondition(try! Data(contentsOf: ssh.appendingPathComponent(identity.label + suffix)) == Data(contentsOf: URL(fileURLWithPath: sourceForName[identity.label]!.path + suffix)))
                } }
            } else { precondition(!evidence.verified && (try! snapshot(target)) == before) }
            precondition(try! staging() == temporary)
        }
        // A normal v1 Bundle is created first, before any external source exists.
        let legacyFiles = ["modules/core/application-interface/core.py", "modules/core/application-interface/capture.py",
                           "modules/migration/package.sh", "modules/migration/ssh-identities.sh"]
        if legacyOnly {
            let baseline = URL(fileURLWithPath: CommandLine.arguments.last!)
            for path in legacyFiles {
                try fm.removeItem(at: core.appendingPathComponent(path))
                try fm.copyItem(at: baseline.appendingPathComponent(path), to: core.appendingPathComponent(path))
            }
        }
        await scan(); identities = capture.secureInventory.items
        sourceForName = Dictionary(uniqueKeysWithValues: identities.map { ($0.label, source.appendingPathComponent(".ssh/" + $0.label)) })
        capture.selectAllSecureIdentities(included: true)
        let legacy = try await publish("legacy")
        if legacyOnly {
            for path in legacyFiles {
                try fm.removeItem(at: core.appendingPathComponent(path))
                try fm.copyItem(at: repository.appendingPathComponent(path), to: core.appendingPathComponent(path))
            }
        }
        try await preview(.importRequired, legacy)
        if legacyOnly {
            print("PASS: Bundle produced by pre-checkpoint production Core is readable by current Secure Preview; bundle-only unlock; target unchanged")
            return
        }
        print("PASS: legacy-compatible Capture/Preview remains readable before adding any external source")

        let outside = root.appendingPathComponent("owned-external"), inHome = source.appendingPathComponent("project-keys")
        try fm.createDirectory(at: outside, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        try fm.createDirectory(at: inHome, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let protected = outside.appendingPathComponent("id_external"), plain = inHome.appendingPathComponent("id_home")
        for suffix in ["", ".pub"] {
            try fm.moveItem(at: source.appendingPathComponent(".ssh/id_disposable" + suffix), to: URL(fileURLWithPath: protected.path + suffix))
        }
        let generate = Process(); generate.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        generate.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", plain.path]
        generate.standardOutput = FileHandle.nullDevice; generate.standardError = FileHandle.nullDevice
        try generate.run(); generate.waitUntilExit(); precondition(generate.terminationStatus == 0)
        await scan()
        let ordinarySelection = capture.selection
        capture.addSSHIdentity(protected); await capture.waitForCompletion()
        if capture.identityError != nil { print("Add reason:", capture.identityError!) }
        precondition(capture.manualIdentityIDs.count == 1 && capture.selectedSecureIdentities.isEmpty && capture.selection == ordinarySelection)
        capture.addSSHIdentity(plain); await capture.waitForCompletion()
        precondition(capture.manualIdentityIDs.count == 2 && capture.selectedSecureIdentities.isEmpty)
        capture.addSSHIdentity(protected); await capture.waitForCompletion(); precondition(capture.identityError != nil && capture.manualIdentityIDs.count == 2)
        let manual = capture.secureInventory.items.first { $0.label == "id_home" }!
        capture.selectSecureIdentity(manual.id, included: true); capture.removeSSHIdentity(manual.id)
        precondition(!capture.selectedSecureIdentities.contains(manual.id) && fm.fileExists(atPath: plain.path))
        capture.addSSHIdentity(plain); await capture.waitForCompletion()
        let duplicateName = inHome.appendingPathComponent("id_external"), duplicatePair = outside.appendingPathComponent("id_alias")
        for suffix in ["", ".pub"] {
            try fm.copyItem(at: URL(fileURLWithPath: plain.path + suffix), to: URL(fileURLWithPath: duplicateName.path + suffix))
            try fm.copyItem(at: URL(fileURLWithPath: protected.path + suffix), to: URL(fileURLWithPath: duplicatePair.path + suffix))
        }
        capture.addSSHIdentity(duplicateName); await capture.waitForCompletion()
        precondition(capture.identityError != nil && capture.manualIdentityIDs.count == 2)
        for duplicate in [duplicateName, duplicatePair] {
            owned.start(CoreRequest(.capturePrepare(selection: nil), externalIdentityPaths: [protected.path, duplicate.path]), location: location(source))
            await owned.waitForCompletion()
            precondition(owned.error == .coreFailure("external_identity_duplicate"))
        }
        for pair in [duplicateName, duplicatePair] { for suffix in ["", ".pub"] { try fm.removeItem(at: URL(fileURLWithPath: pair.path + suffix)) } }
        let sourcesBefore = try snapshot(source), outsideBefore = try snapshot(outside)
        capture.selectAllSecureIdentities(included: true)
        precondition(capture.selectedSecureIdentities.count == 3 && capture.externalDestinationExplanation != nil)
        capture.selectSecureIdentity(manual.id, included: false); precondition(capture.selectedSecureIdentities.count == 2)
        capture.selectAllSecureIdentities(included: true); capture.selectAllSecureIdentities(included: false)
        precondition(capture.selectedSecureIdentities.isEmpty)
        capture.selectAllSecureIdentities(included: true)
        sourceForName = ["id_plain": source.appendingPathComponent(".ssh/id_plain"), "id_external": protected, "id_home": plain]
        let bundle = try await publish("external")
        precondition(try! snapshot(source) == sourcesBefore && snapshot(outside) == outsideBefore)
        print("PASS: Add/Remove stays session-only and default OFF; shared master/individual controls, secure-only Capture and protected external + unprotected HOME pair; sources unchanged")
        let request = CoreRequest(.captureExecute(selection: .init(categories: [], items: [:], secureIdentities: (0..<32).map { String(format:"%064x",$0) }), destination: bundle.path, preparedID: String(repeating:"a",count:64)), externalIdentityPaths: (0..<32).map { "/"+String(repeating:"x",count:900)+String($0) })
        let encoded = try request.encoded(); precondition(encoded.count <= 4096 && encoded.range(of: Data(String(repeating:"x",count:100).utf8)) == nil)
        print("PASS: maximum bounded external references remain outside the 4096-byte Protocol request")
        let inspectBundle = Process()
        inspectBundle.executableURL = python
        inspectBundle.arguments = ["-B", "-c", "import sys;from pathlib import Path;sys.path.insert(0,sys.argv[1]);import bundle;files=bundle.validate_archive(Path(sys.argv[2]));assert 'secure.age' in files;assert not any('external-' in k or 'secure-selection' in k for k in files);assert all(sys.argv[3].encode() not in raw and sys.argv[4].encode() not in raw and b'-----BEGIN OPENSSH PRIVATE KEY-----' not in raw for raw in files.values())", core.appendingPathComponent("modules/bundle").path, bundle.path, protected.path, plain.path]
        inspectBundle.standardOutput = FileHandle.nullDevice; inspectBundle.standardError = FileHandle.nullDevice
        try inspectBundle.run(); inspectBundle.waitUntilExit(); precondition(inspectBundle.terminationStatus == 0)

        if CommandLine.arguments.contains("--custom-destinations-only") {
            await choose(bundle)
            precondition(restore.canCustomizeDestinations)
            restore.customizeDestinations(); let inventoryChallenges = try await interact()
            precondition(inventoryChallenges.map(\.kind) == [.bundleUnlock] && restore.showingDestinations)
            let custom = root.appendingPathComponent("custom-protected"), second = root.appendingPathComponent("custom-plain")
            for directory in [custom, second] { try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            for identity in restore.destinationInventory!.items {
                if identity.name == "id_external" { restore.setDestination(custom.path, for: identity.id) }
                if identity.name == "id_home" { restore.setDestination(second.path, for: identity.id) }
            }
            restore.dismissDestinations()
            let before = try snapshot(target), firstBefore = try snapshot(custom), secondBefore = try snapshot(second), temporary = try staging()
            restore.refreshPreview(); _ = try await interact()
            precondition(restore.preparation?.secureComparison?.decision == .importRequired && restore.canRebuild)
            precondition(try! snapshot(target) == before && snapshot(custom) == firstBefore && snapshot(second) == secondBefore)
            restore.requestRebuild(); restore.confirmRebuild(); _ = try await interact()
            precondition(restore.executionResult?.outcome == .clean && CoreSecureRestoreEvidence(events: restore.categoryPresentationEvents).verified)
            for identity in identities {
                let directory = identity.label == "id_external" ? custom : identity.label == "id_home" ? second : ssh
                for suffix in ["", ".pub"] {
                    let actual = try Data(contentsOf: directory.appendingPathComponent(identity.label + suffix))
                    let expected = try Data(contentsOf: URL(fileURLWithPath: sourceForName[identity.label]!.path + suffix))
                    precondition(actual == expected)
                }
            }
            restore.refreshPreview(); _ = try await interact()
            precondition(restore.preparation?.secureComparison?.decision == .allMatch && !restore.canRebuild)
            precondition(try! snapshot(source) == sourcesBefore && snapshot(outside) == outsideBefore && staging() == temporary)
            let forbidden = [keySecret, bundleSecret] + [protected.path, plain.path, custom.path, second.path].map { Data($0.utf8) }
            for entry in try await logs.history() {
                let report = try await DiagnosticReportBuilder.generate(id: entry.id, environment: .current()) { id, cursor in try await logs.page(id, after: cursor) }
                precondition(forbidden.allSatisfy { report.utf8.range(of: $0) == nil })
            }
            print("PASS: production external Capture -> authenticated Customize -> multiple custom/default Restore -> exact encrypted bytes, Verification and repeated no-op using bundled age; source/target paths absent from diagnostics")
            return
        }


        try await preview(.importRequired, bundle)
        try await execute(cancel: .importConfirmation)
        try await preview(.importRequired, bundle)
        try await execute(cancel: .sshKeyUnlock, interrupt: true)
        try await preview(.importRequired, bundle)
        try await execute()
        try await preview(.allMatch, bundle)
        print("PASS: Bundle-only Preview; import refusal/interruption preserve target; confirmed import uses exact ~/.ssh names in a different HOME and proves Verification; one-requirement no-op")
        let savedPublic = try Data(contentsOf: ssh.appendingPathComponent("id_external.pub"))
        try fm.removeItem(at: ssh.appendingPathComponent("id_external.pub")); try await preview(.conflict, bundle)
        try savedPublic.write(to: ssh.appendingPathComponent("id_external.pub")); try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ssh.appendingPathComponent("id_external.pub").path)
        let savedPrivate = try Data(contentsOf: ssh.appendingPathComponent("id_external"))
        try Data("preserve conflicting fixture".utf8).write(to: ssh.appendingPathComponent("id_external")); try await preview(.conflict, bundle)
        try savedPrivate.write(to: ssh.appendingPathComponent("id_external"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path); try await preview(.conflict, bundle)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        let elsewhere = target.appendingPathComponent("elsewhere")
        try fm.moveItem(at: ssh, to: elsewhere); try await preview(.importRequired, bundle)
        let beforeCancel = try snapshot(target), temporary = try staging()
        restore.refreshPreview(); let cancelled = try await interact(cancel: .bundleUnlock)
        precondition(cancelled.map(\.kind) == [.bundleUnlock] && !restore.canRebuild && (try! snapshot(target)) == beforeCancel && (try! staging()) == temporary)
        try await preview(.importRequired, bundle)
        try fm.createDirectory(at: ssh, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("racing fixture target".utf8).write(to: ssh.appendingPathComponent("id_external")); try fm.setAttributes([.posixPermissions:0o600], ofItemAtPath:ssh.appendingPathComponent("id_external").path)
        let changedTarget = try snapshot(target)
        restore.requestRebuild(); restore.confirmRebuild(); _ = try await interact()
        precondition(!CoreSecureRestoreEvidence(events: restore.categoryPresentationEvents).verified && (try! snapshot(target)) == changedTarget)
        print("PASS: partial/conflicting/unsafe targets -> Needs Attention; keys elsewhere do not count as matches; Preview cancellation and stale target reject without mutation")

        await scan(); capture.addSSHIdentity(protected); await capture.waitForCompletion(); capture.selectAllSecureIdentities(included:true)
        let stale = await prepare("stale-source")
        let publicURL = URL(fileURLWithPath: protected.path+".pub"), publicBytes = try Data(contentsOf: publicURL)
        try (publicBytes + Data("\n".utf8)).write(to: publicURL)
        capture.create(); _ = try await interact()
        precondition(capture.state == .failed && capture.failure?.technicalReason == "stale_prepared_capture" && !fm.fileExists(atPath: stale.path))
        await scan(); capture.addSSHIdentity(protected); await capture.waitForCompletion(); capture.selectAllSecureIdentities(included:true)
        _ = try await publish("changed-during-unlock", changed: { try (publicBytes+Data("\n\n".utf8)).write(to:publicURL) })
        await scan(); capture.addSSHIdentity(protected); await capture.waitForCompletion(); capture.selectAllSecureIdentities(included:true)
        let cancelBundle = await prepare("cancel-capture"), beforeStage = try staging()
        capture.create(); _ = try await interact(cancel:.bundleEncrypt)
        precondition(!fm.fileExists(atPath:cancelBundle.path) && (try! staging()) == beforeStage)
        print("PASS: changed source after Prepare or during unlock prevents publication; Capture cancellation cleans references/plaintext and leaves no Bundle")
        let forbidden = [keySecret,bundleSecret,Data(protected.path.utf8),Data(plain.path.utf8),Data("-----BEGIN OPENSSH PRIVATE KEY-----".utf8)]
        for entry in try await logs.history() {
            let report = try await DiagnosticReportBuilder.generate(id:entry.id,environment:.current()) { id,cursor in try await logs.page(id,after:cursor) }
            precondition(forbidden.allSatisfy { report.utf8.range(of:$0) == nil })
        }
        for directory in [logs.directory,core.appendingPathComponent("logs")] {
            for case let file as URL in fm.enumerator(at:directory,includingPropertiesForKeys:[.isRegularFileKey])?.allObjects ?? [] {
                if (try? file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true {
                    let bytes = try Data(contentsOf:file); precondition(forbidden.allSatisfy { bytes.range(of:$0) == nil })
                }
            }
        }
        precondition(runtime.state == .idle)
        print("PASS: source paths, passphrases and private key material absent from persistent Core/Desktop logs and diagnostic reports")
    }
}
