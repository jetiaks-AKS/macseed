import Foundation
import AppKit
import SwiftUI

@main struct EnvironmentStatusTests {
    typealias Object = [String: Any]
    static func row(_ id: Int, _ kind: String, support: String = "supported", reason: String? = nil) -> Object {
        ["record_id": "v:\(id)", "domain": "homebrew-packages", "item_id": "item-\(id)",
         "comparison_kind": kind, "support": support, "reason": reason ?? NSNull(), "phase": NSNull()]
    }
    static func payload(_ rows: [Object], verdict: String, unresolved: Bool = false,
                        extras: Object = ["domains": [], "items": []], alsoIncomplete: Bool = false) -> Object {
        var counts = ["matching": 0, "missing": 0, "differing": 0, "unverified": 0, "unsupported": 0,
                      "unresolved": unresolved ? 1 : 0, "extra": (extras["items"] as! [Object]).count, "unknown_difference": 0]
        for row in rows {
            counts[row["comparison_kind"] as! String, default: 0] += 1
            if row["support"] as! String == "unsupported" { counts["unsupported", default: 0] += 1 }
            if row["reason"] as? String == "unknown_difference" { counts["unknown_difference", default: 0] += 1 }
        }
        let coverage: [Object] = unresolved ? [["record_id": "c:0", "domain": "homebrew-packages", "item_id": "unknown",
                                                "disposition": "unresolved", "source_status": "unknown"]] : []
        return ["read_only": true, "publication_occurred": false, "target_mutation_may_have_started": false,
                "comparison": ["status": "complete", "verdict": verdict, "also_incomplete": alsoIncomplete, "counts": counts],
                "comparison_records": rows, "verification": ["status": "complete"], "extra": extras,
                "records": ["status": "complete", "verification_records": [], "coverage_records": coverage,
                            "operation_records": [], "diagnostics": []]]
    }
    static func data(_ object: Object) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    static func presentation(_ object: Object) throws -> EnvironmentStatusPresentation {
        try EnvironmentStatusPresentation(JSONDecoder().decode(CoreComparisonResult.self, from: data(object)))
    }
    static func rejected(_ object: Object) {
        do { _ = try presentation(object); preconditionFailure("Invalid comparison must fail closed") } catch {}
    }
    static func write(_ text: String, _ url: URL, executable: Bool = false) throws {
        try text.write(to: url, atomically: false, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
    }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    @MainActor static func render<V: View>(_ view: V, name: String, width: Int) throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        let height = 800
        let root = HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Macseed").font(.title2.weight(.semibold))
                Label("All Tasks", systemImage: "square.grid.2x2")
                ForEach(ProductTask.allCases) { task in Label(task.rawValue, systemImage: task.symbol) }
                Spacer()
            }.padding(20).frame(width: 215).background(.regularMaterial)
            ScrollView { view.modifier(WorkspaceContentGeometry()) }
        }.frame(width: CGFloat(width), height: CGFloat(height)).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { preconditionFailure("Native render unavailable") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/Debug/\(name).png"))
        window.close()
    }

    @MainActor static func main() async throws {
        let renderRuntime = CoreRuntime()
        let renderModel = EnvironmentStatusModel(runtime: renderRuntime)
        for (label, width) in [("narrow", 1000), ("wide", 1600)] {
            try render(TaskHome(select: { _ in }), name: "AllTasksUIv2-" + label, width: width)
            try render(VStack(alignment: .leading, spacing: 20) {
                WorkspaceHeader(title: ProductTask.status.rawValue, subtitle: ProductTask.status.subtitle, symbol: ProductTask.status.symbol)
                EnvironmentStatusView(model: renderModel, runtime: renderRuntime)
            }, name: "EnvironmentStatusUIv2-initial-" + label, width: width)
        }
        let visualResult = try presentation(payload([row(0, "matching"), row(1, "differing"), row(2, "missing"), row(3, "unverified", reason: "observation_failed")], verdict: "differences_detected", alsoIncomplete: true))
        precondition(visualResult.counts["matching"] == 1 && visualResult.counts["missing"] == 1)
        precondition(visualResult.categories.map(\.id) == ["homebrew-packages"])
        print("PASS: native All Tasks/Status narrow/wide renders and real comparison taxonomy/counts")
        let clean = payload([row(0, "matching")], verdict: "no_differences_detected")
        let ready = try presentation(clean)
        precondition(ready.headline == "No differences detected" && !ready.needsAttention && ready.summary == "1 matching")
        precondition(ready.categories[0].items[0].status == .matching && !ready.categories[0].hasAttention)
        for kind in ["missing", "differing"] {
            let value = try presentation(payload([row(0, kind)], verdict: "differences_detected"))
            precondition(value.needsAttention && value.categories[0].hasAttention && !value.summary.contains("0 "))
            precondition(value.categories[0].items[0].status == (kind == "missing" ? .missing : .different))
        }
        let unsupported = try presentation(payload([row(0, "unverified", support: "unsupported", reason: "unsupported_predicate")], verdict: "incomplete"))
        precondition(unsupported.categories[0].items[0].status == .unsupported)
        precondition(unsupported.summary == "1 unverified · 1 unsupported (within unverified)")
        precondition(ComparisonOutcome.notApplicable.count(unsupported) == 0)
        var noRequirementPayload = payload([], verdict: "no_comparable_requirements")
        var noRequirementRecords = noRequirementPayload["records"] as! Object
        noRequirementRecords["coverage_records"] = [
            ["record_id": "c:0", "domain": "homebrew-packages", "item_id": "scope", "disposition": "no_requirement", "source_status": "unknown"],
            ["record_id": "c:1", "domain": "homebrew-casks", "item_id": "scope", "disposition": "excluded", "source_status": "unknown"]]
        noRequirementPayload["records"] = noRequirementRecords
        let notApplicable = try presentation(noRequirementPayload)
        precondition(ComparisonOutcome.notApplicable.count(notApplicable) == 1)
        precondition(notApplicable.categories.flatMap(\.items).contains { $0.status == .excluded })
        precondition(ComparisonOutcome.allCases.map { $0.count(visualResult) } == [1, 1, 1, 0])
        let unknown = try presentation(payload([row(0, "unverified", reason: "unknown_difference")], verdict: "incomplete"))
        precondition(unknown.categories[0].items[0].status == .unverified && unknown.summary.contains("unknown difference"))
        let mixed = try presentation(payload([row(0, "matching"), row(1, "differing"), row(2, "unverified", reason: "observation_failed")],
                                             verdict: "differences_detected", unresolved: true, alsoIncomplete: true))
        precondition(mixed.summary == "1 matching · 1 different · 1 unverified · 1 unresolved")
        precondition(mixed.message.contains("could not be verified") && mixed.categories[0].hasAttention)
        precondition(mixed.categories[0].items.contains { $0.status == .unresolved })
        let observation = try presentation(payload([row(0, "unverified", reason: "observation_failed")], verdict: "incomplete"))
        precondition(observation.categories[0].items[0].action == "Core could not observe current state.")
        let empty = try presentation(payload([], verdict: "no_comparable_requirements"))
        precondition(empty.headline == "No comparable requirements" && empty.summary.isEmpty && !empty.needsAttention)
        print("PASS: Core verdicts/states, observation failure, mixed/unresolved and zero-count suppression")

        let unavailable: Object = ["domains": [["domain": "homebrew-casks", "status": "unavailable", "count": NSNull(),
                                               "reason": "reference_inventory_completeness_unknown"]], "items": []]
        let noExtras = try presentation(payload([row(0, "matching")], verdict: "no_differences_detected", extras: unavailable))
        precondition(!noExtras.needsAttention && !noExtras.summary.contains("extra"))
        precondition(noExtras.categories.flatMap(\.items).contains { $0.action.contains("cannot be determined") })
        let available: Object = ["domains": [["domain": "homebrew-casks", "status": "available", "count": 1, "reason": NSNull()]],
                                 "items": [["domain": "homebrew-casks", "item_id": "extra-app"]]]
        let extras = try presentation(payload([], verdict: "differences_detected", extras: available))
        precondition(extras.summary == "1 extra" && extras.categories[0].items[0].status == .extra)
        precondition(extras.categories[0].items[0].action.contains("Nothing will be removed"))
        var forged = unavailable
        forged["items"] = available["items"]
        rejected(payload([], verdict: "differences_detected", extras: forged))
        let unsupportedDomain: Object = ["domains": [["domain": "homebrew-packages", "status": "available", "count": 1]],
                                        "items": [["domain": "homebrew-packages", "item_id": "formula"]]]
        rejected(payload([], verdict: "differences_detected", extras: unsupportedDomain))
        var invalid = clean
        invalid["read_only"] = false; rejected(invalid)
        invalid = clean; invalid["publication_occurred"] = true; rejected(invalid)
        invalid = clean; invalid["target_mutation_may_have_started"] = true; rejected(invalid)
        invalid = clean
        var records = invalid["records"] as! Object
        records["status"] = "truncated"; invalid["records"] = records; rejected(invalid)
        invalid = payload([row(0, "missing")], verdict: "no_differences_detected"); rejected(invalid)
        invalid = clean
        records = invalid["records"] as! Object
        records["diagnostics"] = [["record_id": "run", "code": "observation_failed", "severity": "warning", "phase": "observation"]]
        invalid["records"] = records
        let warning = try presentation(invalid)
        precondition(warning.needsAttention && warning.categories.last!.hasAttention)
        precondition(warning.categories[0].items[0].status == .matching)
        print("PASS: Extras provenance/status gating, read-only evidence, incomplete/contradictory result rejection and warnings")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macseed-status-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = directory.appendingPathComponent("fake-core")
        try FileManager.default.createDirectory(at: core.appendingPathComponent("modules/core/application-interface"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: core.appendingPathComponent("config"), withIntermediateDirectories: true)
        for path in ["modules/core/application-interface/core.py", "config/toolkit.conf", "bootstrap.sh"] { try Data().write(to: core.appendingPathComponent(path)) }
        try write("#!/bin/bash\nexec python3 -B fixture.py\n", core.appendingPathComponent("modules/core/application-interface/core.sh"))
        let python = URL(fileURLWithPath: CommandLine.arguments[2])
        try write("""
        import json, sys, pathlib, signal, time, os
        request = json.loads(sys.stdin.buffer.read())
        assert request['operation'] == 'environment_compare'
        with open('requests.jsonl', 'a') as stream: stream.write(json.dumps(request) + '\\n')
        mode = pathlib.Path('mode').read_text()
        sequence = 0
        def emit(kind, data=None):
            global sequence
            sequence += 1
            event = dict(protocol_version=1, operation_id=request['operation_id'], sequence=sequence, type=kind)
            if data is not None: event['data'] = data
            print(json.dumps(event), flush=True)
        def stop(signum, frame):
            emit('cancelled', dict(read_only=True, publication_occurred=False, target_mutation_may_have_started=False))
            sys.exit(130)
        signal.signal(signal.SIGTERM, stop)
        emit('started')
        if mode == 'slow':
            while True: time.sleep(.05)
        if mode == 'interrupt': os.kill(os.getpid(), signal.SIGKILL)
        if mode == 'protocol': print('not JSON', flush=True); sys.exit(0)
        if mode == 'success' or mode == 'reference_invalid_after_result': emit('result', json.loads(pathlib.Path('response.json').read_text()))
        if mode == 'success': emit('completed', dict(read_only=True)); sys.exit(0)
        emit('failed', dict(code='reference_invalid' if mode == 'reference_invalid_after_result' else mode, read_only=True))
        sys.exit(2)
        """, core.appendingPathComponent("fixture.py"))
        try data(clean).write(to: core.appendingPathComponent("response.json"))
        try write("success", core.appendingPathComponent("mode"))
        let reference = directory.appendingPathComponent("generated")
        try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: false)
        let blueprint = directory.appendingPathComponent("blueprint.conf")
        try write("fixture", blueprint)
        let location = CoreLocation(root: core, python: python, home: directory, temporaryBase: directory, toolDirectories: [])
        let runtime = CoreRuntime()
        let model = EnvironmentStatusModel(runtime: runtime, location: location)
        model.compare()
        precondition(model.failure == .noReference && runtime.state == .idle)
        model.selectReference(directory.appendingPathComponent("absent"))
        model.compare()
        precondition(model.failure == .referenceUnavailable && runtime.state == .idle)
        model.selectReference(blueprint) // A Bundle/file is not a Generated Configuration folder.
        model.compare()
        precondition(model.failure == .referenceUnavailable && runtime.state == .idle)
        model.selectReference(reference)
        model.selectBlueprint(directory.appendingPathComponent("absent.conf")); model.compare()
        precondition(model.failure == .referenceUnavailable)
        model.selectBlueprint(nil)
        model.compare(); await model.waitForCompletion()
        precondition(model.state == .result && model.presentation?.headline == "No differences detected")
        let firstID = model.operationID
        try data(payload([row(0, "matching"), row(1, "differing"), row(2, "missing"), row(3, "unverified", reason: "observation_failed")], verdict: "differences_detected", alsoIncomplete: true)).write(to: core.appendingPathComponent("response.json"))
        model.selectBlueprint(blueprint)
        model.compare(); await model.waitForCompletion()
        precondition(model.operationID != firstID && model.presentation?.headline == "Needs Attention")
        // Check Again changes neither reference nor Blueprint and always creates a new request.
        let secondID = model.operationID
        model.compare(); await model.waitForCompletion()
        precondition(model.operationID != secondID && model.reference?.blueprint == blueprint)
        for (label, width) in [("narrow", 1000), ("wide", 1600)] {
            try render(EnvironmentStatusView(model: model, runtime: runtime), name: "EnvironmentStatusUIv2-result-" + label, width: width)
        }
        let requests = try String(contentsOf: core.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n")
        precondition(requests.count == 3)
        let sent = try requests.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! Object }
        precondition(Set(sent.map { $0["operation_id"] as! String }).count == 3)
        precondition((sent[0]["parameters"] as! Object)["blueprint_path"] is NSNull)
        precondition((sent[2]["parameters"] as! Object)["blueprint_path"] as? String == blueprint.path)
        precondition(sent.allSatisfy { $0["operation"] as? String == "environment_compare" })
        print("PASS: Missing/unavailable reference, explicit Blueprint/null and fresh Check Again requests/results")

        for mode in ["reference_invalid", "reference_unavailable", "reference_changed", "comparison_reporting_incomplete", "reference_invalid_after_result", "protocol", "interrupt"] {
            try write(mode, core.appendingPathComponent("mode"))
            model.compare(); precondition(model.presentation == nil)
            await model.waitForCompletion()
            precondition(model.state == .failed && model.presentation == nil && model.failure != nil)
            if mode == "interrupt" { precondition(model.failure == .interrupted) }
            if mode == "reference_invalid_after_result" { precondition(model.failure == .runtime(.coreFailure("reference_invalid"))) }
        }
        try write("slow", core.appendingPathComponent("mode"))
        model.compare()
        for _ in 0..<100 where runtime.events.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(model.state == .running && runtime.state == .running)
        model.cancel(); await model.waitForCompletion()
        precondition(model.state == .cancelled && model.presentation == nil && model.failure == .cancelled)
        let missingRuntime = EnvironmentStatusModel(runtime: CoreRuntime(resolver: CoreLocationResolver(resources: directory.appendingPathComponent("no-runtime"))))
        missingRuntime.selectReference(reference); missingRuntime.compare(); await missingRuntime.waitForCompletion()
        precondition(missingRuntime.state == .failed && missingRuntime.failure == .runtime(.runtimeUnavailable) && missingRuntime.presentation == nil)
        #if DEBUG
        let sample = DemoSession()
        sample.load(.differences)
        let sampleCategories = sample.statusCategories
        sample.compare()
        precondition(sample.statusCategories == sampleCategories && missingRuntime.presentation == nil)
        #else
        precondition(!BuildFeatures.sampleExperience)
        #endif
        print("PASS: Failed/partial result cannot appear clean, protocol/interruption/cancel handling and sample isolation")

        try await realCoreTest(directory: directory, repository: URL(fileURLWithPath: CommandLine.arguments[1]), python: python)
    }

    static func snapshot(_ directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for case let url as URL in FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])! {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { result[url.path] = try Data(contentsOf: url) }
        }
        return result
    }
    @MainActor static func realCoreTest(directory: URL, repository: URL, python: URL) async throws {
        // Automated disposable fixture, never the user's reference/current-Mac manual gate.
        let core = directory.appendingPathComponent("real-core")
        try FileManager.default.createDirectory(at: core.appendingPathComponent("config"), withIntermediateDirectories: true)
        for name in ["modules", "bootstrap.sh", "config/toolkit.conf"] {
            try FileManager.default.copyItem(at: repository.appendingPathComponent(name), to: core.appendingPathComponent(name))
        }
        let generated = directory.appendingPathComponent("real-generated")
        let home = directory.appendingPathComponent("real-home")
        let bin = directory.appendingPathComponent("real-bin")
        for url in [generated, home, bin] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        let mode = bin.appendingPathComponent("mode")
        let marker = directory.appendingPathComponent("mutation-attempts")
        try write("matching", mode)
        try write("""
        #!/bin/bash
        if [[ "$*" != 'list --formula --full-name' ]]; then echo "$*" >> \(quote(marker.path)); exit 99; fi
        case "$(/bin/cat \(quote(mode.path)))" in
          matching) echo git;;
          missing) exit 0;;
          observation_error) exit 2;;
        esac
        """, bin.appendingPathComponent("brew"), executable: true)
        for name in ["sudo", "defaults", "killall", "mas", "code", "curl", "xcode-select"] {
            try write("#!/bin/bash\necho attempted >> " + quote(marker.path) + "\nexit 99\n", bin.appendingPathComponent(name), executable: true)
        }
        try write("git\n", generated.appendingPathComponent("brew-packages.conf"))
        let blueprint = directory.appendingPathComponent("real-blueprint.conf")
        let categories = ["git-configuration", "ssh-configuration", "vscode-settings", "shell-zsh", "macos-finder", "macos-dock", "macos-windows", "macos-keyboard", "macos-trackpad", "macos-screenshots"]
        try write("[categories]\n" + categories.map { $0 + "=\"false\"\n" }.joined()
                  + "[homebrew-packages]\ngit\n[homebrew-casks]\n[app-store]\n[vscode-extensions]\n[workspace-folders]\n[git-repositories]\n", blueprint)
        let beforeReference = try snapshot(generated), beforeHome = try snapshot(home), beforeBlueprint = try Data(contentsOf: blueprint)
        let runtime = CoreRuntime()
        let model = EnvironmentStatusModel(runtime: runtime, location: CoreLocation(root: core, python: python, home: home,
                                                                                  temporaryBase: directory, toolDirectories: [bin]))
        model.selectReference(generated); model.selectBlueprint(blueprint)
        for modeName in ["matching", "missing", "observation_error"] {
            try write(modeName, mode)
            model.compare(); await model.waitForCompletion()
            precondition(model.state == .result, "Actual Core projection rejected: \(String(describing: model.failure))")
            precondition(model.presentation?.headline == (modeName == "matching" ? "No differences detected" : "Needs Attention"))
            precondition(runtime.latestResult?.data?["read_only"] == .bool(true))
            if modeName == "observation_error" { precondition(model.presentation?.categories.flatMap(\.items).contains { $0.status == .unverified } == true) }
        }
        try write("invalid!\n", blueprint)
        model.compare(); await model.waitForCompletion()
        precondition(model.state == .failed && model.failure == .runtime(.coreFailure("reference_invalid")) && model.presentation == nil)
        try beforeBlueprint.write(to: blueprint)
        let afterReference = try snapshot(generated), afterHome = try snapshot(home), afterBlueprint = try Data(contentsOf: blueprint)
        precondition(afterReference == beforeReference && afterHome == beforeHome && afterBlueprint == beforeBlueprint)
        precondition(!FileManager.default.fileExists(atPath: marker.path) && !FileManager.default.fileExists(atPath: core.appendingPathComponent("logs").path))
        print("PASS: Swift → production Core → disposable readers → Status (matching/difference/observation/invalid reference); no mutation")
    }
}
