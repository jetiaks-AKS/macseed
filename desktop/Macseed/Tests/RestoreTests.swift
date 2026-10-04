import Foundation

@main struct RestoreTests {
    static func write(_ value: String, _ path: URL) throws { try value.write(to: path, atomically: false, encoding: .utf8) }
    @MainActor static func main() async throws {
        let repo = URL(fileURLWithPath: CommandLine.arguments[1])
        let python = URL(fileURLWithPath: CommandLine.arguments[2])
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("macseed-desktop-restore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = root.appendingPathComponent("fake")
        try FileManager.default.createDirectory(at: core.appendingPathComponent("modules/core/application-interface"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: core.appendingPathComponent("config"), withIntermediateDirectories: true)
        for path in ["bootstrap.sh", "config/toolkit.conf", "modules/core/application-interface/core.py"] { try Data().write(to: core.appendingPathComponent(path)) }
        try write("#!/bin/bash\nexec python3 -B fixture.py\n", core.appendingPathComponent("modules/core/application-interface/core.sh"))
        try write("""
        import json, sys, time, os, signal
        from pathlib import Path
        request=json.load(sys.stdin)
        with open('requests.jsonl','a') as out: out.write(json.dumps(request)+'\\n')
        mode=Path('mode').read_text() if Path('mode').exists() else 'clean'
        sequence=0
        def emit(kind,data=None):
            global sequence
            sequence+=1
            row=dict(protocol_version=1,operation_id=request['operation_id'],sequence=sequence,type=kind)
            if data is not None: row['data']=data
            print(json.dumps(row),flush=True)
        def cancelled(signum, frame):
            emit('cancelled',{'code':'cancelled'}); sys.exit(130)
        signal.signal(signal.SIGTERM,cancelled)
        emit('started')
        operation=request['operation']
        if operation=='capabilities':
            features={} if mode=='old_core' else {'restore_selection':{'version':1}}
            result=dict(protocol_version=1, product_version='3.4.0',operations=['bundle_inspect','restore_prepare'],features=features)
        elif operation=='bundle_inspect':
            if mode in ('bundle_invalid','unsupported_bundle'):
                emit('failed',{'code':mode}); sys.exit(2)
            result=json.loads(Path('inspection.json').read_text())
        elif operation=='restore_prepare':
            if mode in ('slow','interrupted'):
                emit('phase_started',{'phase':'preparation'})
                if mode=='interrupted': os.kill(os.getpid(),signal.SIGKILL)
                time.sleep(20)
            if mode=='prepare_failure': emit('failed',{'code':'preview_failed'}); sys.exit(2)
            assert request['parameters']['include_secure'] is False
            assert request['parameters']['disabled_groups']==[]
            requested=request['parameters']['selection']
            catalog=json.loads(Path('inspection.json').read_text())['restore_selection']
            selected_categories=[]; selected_items={}; plan=[]
            for area in catalog['inventory']:
                domain=area['domain']
                if domain in requested['categories']:
                    if area['selection_mode']=='category': selected_categories.append(domain)
                    else: selected_items[domain]=[x['item_id'] for x in area['items']]
                elif domain in requested['items']: selected_items[domain]=requested['items'][domain]
                if domain in selected_categories:
                    plan.append(dict(domain=domain,item_id='scope',action='set_setting',disposition='planned',reason=None))
                for index,item in enumerate(selected_items.get(domain,[])):
                    disposition=['satisfied','planned','warning','conflict'][index%4] if mode=='attention' else 'planned'
                    plan.append(dict(domain=domain,item_id=str(index+1),selection_item_id=item,action='install',disposition=disposition,reason='target_conflict' if disposition=='conflict' else None))
            selected=set(selected_categories)|set(selected_items)
            groups=[group['id'] for group in catalog['groups'] if selected.intersection(group['domains'])]
            conditions=[] if mode!='attention' else [dict(domain='homebrew-packages',code='homebrew_installation_requires_interaction',status='external_action_required')]
            if mode=='safe': conditions=[dict(domain='homebrew-packages',code='homebrew_path_activation',status='safely_satisfiable')]
            if mode=='satisfied': conditions=[dict(domain='homebrew-packages',code='ready',status='satisfied')]
            if mode=='unsupported_condition': conditions=[dict(domain='homebrew-packages',code='unsupported_interactive_operation',status='unsupported')]
            result=dict(prepared_plan_id=('b' if mode=='safe' else 'a')*64,
                selection=dict(categories=sorted(selected_categories),items={k:sorted(v) for k,v in selected_items.items()}),
                selected_groups=groups, selected_categories=selected_categories,selected_item_counts={k:len(v) for k,v in selected_items.items()},
                include_secure=False,secure_restore_status='not_selected',plan=plan,readiness=dict(ready=not conditions or mode in ('safe','satisfied'),ready_scope='environment',conditions=conditions,reentry='restore_prepare'),
                has_planned_changes=mode not in ('no_changes','no_changes_attention'),warning_count=1 if mode=='attention' else 0,error_count=0)
            if mode in ('no_changes','no_changes_attention'):
                for row in result['plan']: row['disposition']='satisfied'
                if mode=='no_changes_attention': result['plan'][0]['disposition']='warning'
            if mode=='wrong_selection': result['selection']['categories']=['not-chosen']
        elif operation=='restore_execute':
            assert request['parameters']['include_secure'] is False
            assert request['parameters']['selection'] is not None
            requests=[json.loads(line) for line in Path('requests.jsonl').read_text().splitlines()]
            last_prepare=next(r for r in reversed(requests) if r['operation']=='restore_prepare')
            assert request['parameters']['selection']==last_prepare['parameters']['selection']
            assert request['parameters']['expected_prepared_plan_id']=='a'*64
            if mode=='execute_missing_result': emit('completed'); sys.exit(0)
            if mode=='execute_interrupted':
                emit('phase_started',dict(phase='bootstrap')); os._exit(9)
            if mode in ('execute_stop_before','execute_stop_after'):
                mutation=mode=='execute_stop_after'
                def stop(signum,frame):
                    emit('failed',dict(code='cancelled',target_mutation_may_have_started=mutation)); sys.exit(130)
                signal.signal(signal.SIGTERM,stop)
                emit('phase_started',dict(phase='bootstrap' if mutation else 'preparation'))
                time.sleep(10)
            if mode in ('execute_fail_before','execute_fail_after','execute_stale'):
                emit('failed',dict(code='stale_plan' if mode=='execute_stale' else 'bootstrap_failed',target_mutation_may_have_started=mode=='execute_fail_after')); sys.exit(2)
            emit('phase_started',dict(phase='bootstrap'))
            emit('execution_event',dict(domain='homebrew-packages',item_id='first',state='changed',action='install'))
            verification=dict(status='complete',verdict='selected_requirements_verified',mismatch_count=0,unverified_count=0,unresolved_count=0,warning_count=0,error_count=0,details={})
            if mode=='execute_attention': verification['unverified_count']=1; verification['verdict']='incomplete'
            result=dict(prepared_plan_id='a'*64,execution_status='completed',target_mutation_may_have_started=True,publication_occurred=True,verification=verification,warning_count=0,error_count=0)
        else:
            Path('MUTATION_ATTEMPT').write_text(operation)
            emit('failed',dict(code='forbidden_operation')); sys.exit(2)
        emit('result',result); emit('completed')
        """, core.appendingPathComponent("fixture.py"))
        let macOS = ["finder", "dock", "windows", "keyboard", "trackpad", "screenshots"].map { "macos-" + $0 }
        let applications = ["homebrew-casks", "app-store", "vscode-extensions"]
        let workspace = ["workspace-folders", "git-repositories"]
        let itemDomains = ["homebrew-packages"] + applications + workspace
        var inventory: [[String: Any]] = itemDomains.map { domain in
            ["domain": domain, "label": "Core label " + domain, "selection_mode": "items", "availability": "available", "reason": NSNull(),
             "items": (1...4).map { ["item_id": "stable-\(domain)-\($0)", "label": "Core item \($0)"] }]
        }
        inventory += macOS.map { ["domain": $0, "label": "Core label " + $0, "selection_mode": "category", "availability": "available", "reason": NSNull(), "items": []] }
        inventory += [["domain": "ssh-configuration", "label": "SSH Configuration", "selection_mode": "category", "availability": "available", "reason": NSNull(), "items": []],
                      ["domain": "unavailable-area", "label": "Unavailable area", "selection_mode": "category", "availability": "unavailable", "reason": "no_selectable_content", "items": []]]
        let groups: [[String: Any]] = [["id": "Applications", "domains": applications], ["id": "Workspace", "domains": workspace],
                                      ["id": "macOS Settings", "domains": macOS], ["id": "Other Core group", "domains": ["homebrew-packages", "ssh-configuration", "unavailable-area"]]]
        let inspection: [String: Any] = ["format_version": 1, "selected_categories": macOS + ["ssh-configuration"], "selected_item_counts": [:], "secure_component": true,
                                        "restore_selection": ["groups": groups, "inventory": inventory]]
        try JSONSerialization.data(withJSONObject: inspection).write(to: core.appendingPathComponent("inspection.json"))
        let runtime = CoreRuntime()
        let model = RestoreModel(runtime: runtime, location: CoreLocation(root: core, python: python, home: root, temporaryBase: root, toolDirectories: []))
        let source = root.appendingPathComponent("sample.mbt")
        model.choose(source); await model.waitForCompletion()
        precondition(model.state == .review && model.areas.count == inventory.count && model.groups.count == 4 && model.bulkState == .all)
        precondition(model.selectionSummary == "Everything selected" && model.canPreview)
        precondition(model.inspection?.secureComponent == true && model.selectedAreaCount == 13)
        for id in applications + workspace {
            model.selectArea(id, included: false)
            precondition(!model.selection.categories.contains(id))
            model.selectArea(id, included: true)
        }
        let presentationGroups = model.groups + [CoreRestoreInspection.Group(id: "Homebrew", domains: ["homebrew-packages"])]
        let sections = RestorePresentationSection.project(presentationGroups)
        precondition(sections.map(\.id) == ["Applications & Tools", "Settings", "Shell", "Git", "SSH Configuration", "Workspace"])
        precondition(sections[0].areas(in: model.areas).map(\.id) == ["homebrew-casks", "app-store", "homebrew-packages", "vscode-extensions"])
        precondition(sections[1].groups.map(\.id) == ["macOS Settings"])
        precondition(sections[5].areas(in: model.areas).map(\.id) == workspace)
        precondition(RestorePresentationSection.project(presentationGroups.reversed()).map(\.id) == sections.map(\.id))
        for id in applications + workspace + ["homebrew-packages"] {
            let area = model.areas.first { $0.id == id }!
            model.selectItem(id, item: area.items[0].id, included: false)
            precondition(model.selectionState(area) == .mixed && model.selection.items[id]?.count == 3)
            model.selectArea(id, included: true)
        }
        let shellGroup = CoreRestoreInspection.Group(id: "Shell", domains: ["unavailable-area"])
        let visibleGroups = presentationGroups + [shellGroup]
        let inventoryBefore = model.areas.map(\.id)
        let selectionBefore = model.canonicalSelection
        let visible = RestorePresentationSection.visible(visibleGroups, inventory: model.areas)
        precondition(!visible.contains { $0.id == "Shell" })
        precondition(visible.contains { $0.id == "Settings" } && visible.contains { $0.id == "Applications & Tools" })
        let availableShell = CoreRestoreInspection.Group(id: "Shell", domains: ["ssh-configuration", "unavailable-area"])
        precondition(RestorePresentationSection.visible([availableShell], inventory: model.areas).map(\.id) == ["Shell"])
        precondition(model.areas.map(\.id) == inventoryBefore && model.canonicalSelection == selectionBefore)
        precondition(model.areas.first { $0.id == "unavailable-area" }?.reason == "no_selectable_content")
        let macOSGroup = model.groups.first { $0.id == "macOS Settings" }!
        model.selectArea("macos-dock", included: false)
        precondition(model.groupState(macOSGroup) == .mixed && model.selectedAreaCount == 12)
        model.selectGroup(macOSGroup, included: false); precondition(model.groupState(macOSGroup) == .none && model.selectionSummary == "Some items excluded")
        model.selectGroup(macOSGroup, included: true); precondition(model.groupState(macOSGroup) == .all && model.selectionSummary == "Everything selected")
        model.selectItem("macos-dock", item: "invented", included: false)
        precondition(model.selectedCategories.contains("macos-dock"))
        let packages = model.areas.first { $0.id == "homebrew-packages" }!
        model.selectItem(packages.id, item: packages.items[0].id, included: false)
        precondition(model.selectionSummary == "Some items excluded")
        precondition(model.selectionState(packages) == .mixed && model.selection.items[packages.id]?.count == 3)
        model.selectArea("unavailable-area", included: true); precondition(!model.selection.categories.contains("unavailable-area"))
        model.refreshPreview(); await model.waitForCompletion()
        precondition(model.state == .preview && model.ready && model.preparation?.preparedPlanID == String(repeating: "a", count: 64))
        precondition(model.preview?.categories.first { $0.id == packages.id }?.items.first?.title == "Core item 2")
        let productPreview = model.preview!
        precondition(productPreview.sections.map(\.id) == ["Applications & Tools", "Settings", "Workspace"])
        let settingsRows = productPreview.sections.first { $0.id == "Settings" }!.rows
        precondition(settingsRows.count == 1 && settingsRows[0].id == "macOS Settings")
        precondition(settingsRows[0].items.count == macOS.count)
        precondition(RestorePreviewPresentation.state(settingsRows[0]) == "Changes Planned")
        precondition(RestorePreviewPresentation.summary(changes: 0, matches: 122, attention: 1) == "0 changes · 122 already match · 1 needs attention")
        precondition(RestorePreviewPresentation.summary(changes: 1, matches: 1, attention: 2) == "1 change · 1 already matches · 2 need attention")
        let matching = DisplayCategory(id: "matches", title: "Matches", symbol: "checkmark.circle", items: [DisplayItem(id: "match", title: "Item", status: .matching, action: "Already Matches")])
        precondition(RestorePreviewPresentation.state(matching) == "Already Matches")
        for status in [DisplayStatus.unverified, .unsupported, .attention, .unresolved] {
            let aggregate = DisplayCategory(id: "macOS Settings", title: "macOS Settings", symbol: "slider.horizontal.3", items: settingsRows[0].items + [DisplayItem(id: "attention", title: "Detail", status: status, action: "Needs Attention")])
            precondition(RestorePreviewPresentation.state(aggregate) == "Needs Attention")
        }
        model.selectItem(packages.id, item: packages.items[0].id, included: true)
        precondition(model.preparation == nil && model.preview == nil && model.state == .review)
        try write("attention", core.appendingPathComponent("mode"))
        model.refreshPreview(); await model.waitForCompletion()
        precondition(model.state == .preview && !model.ready && model.preparation?.readiness.conditions.first?.status == "external_action_required")
        let projected = model.preview!.categories.first { $0.id == packages.id }!.items
        precondition(projected.map(\.action).contains("Already Matches") && projected.map(\.action).contains("Will install"))
        precondition(projected.contains { $0.action.hasPrefix("Conflict:") } && projected.contains { $0.requiresAttention })
        let oldOperation = runtime.operationID
        try write("safe", core.appendingPathComponent("mode")); model.refreshPreview(); await model.waitForCompletion()
        precondition(runtime.operationID != oldOperation && model.ready && model.preparation?.preparedPlanID == String(repeating: "b", count: 64))
        precondition(model.preparation?.readiness.conditions.first?.status == "safely_satisfiable")
        for mode in ["satisfied", "unsupported_condition"] {
            try write(mode, core.appendingPathComponent("mode")); model.refreshPreview(); await model.waitForCompletion()
            precondition(model.state == .preview && model.ready == (mode == "satisfied"))
        }
        model.back(); precondition(model.state == .review && model.preparation == nil && model.bulkState == .all)
        model.toggleAll(); precondition(model.selectedAreaCount == 0 && !model.canPreview && model.selectionSummary == "Nothing selected")
        model.toggleAll(); precondition(model.bulkState == .all && model.selectionSummary == "Everything selected")
        for mode in ["prepare_failure", "wrong_selection", "interrupted"] {
            try write(mode, core.appendingPathComponent("mode")); model.refreshPreview(); await model.waitForCompletion()
            precondition(model.state == .failed && model.preparation == nil && model.preview == nil)
        }
        try write("slow", core.appendingPathComponent("mode")); model.refreshPreview()
        for _ in 0..<100 { if runtime.isActive && runtime.currentPhase == "preparation" { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        model.cancel(); await model.waitForCompletion()
        precondition(model.state == .cancelled && model.preparation == nil && model.preview == nil)
        model.refreshPreview(); model.cancel(); await model.waitForCompletion()
        precondition(model.state == .cancelled && model.preparation == nil)
        for mode in ["old_core", "bundle_invalid", "unsupported_bundle"] {
            try write(mode, core.appendingPathComponent("mode")); model.choose(root.appendingPathComponent("another.mbt")); await model.waitForCompletion()
            precondition(model.state == .failed && model.inspection == nil && model.preparation == nil)
        }
        try write("clean", core.appendingPathComponent("mode")); model.choose(source); await model.waitForCompletion()
        model.refreshPreview(); await model.waitForCompletion()
        model.choose(root.appendingPathComponent("changed.mbt"))
        precondition(model.preparation == nil && model.preview == nil)
        await model.waitForCompletion()
        let requests = try String(contentsOf: core.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        precondition(requests.allSatisfy { ["capabilities", "bundle_inspect", "restore_prepare"].contains($0["operation"] as! String) })
        precondition(!FileManager.default.fileExists(atPath: core.appendingPathComponent("MUTATION_ATTEMPT").path))
        print("PASS: Capability/inventory, independent areas/groups/items, stable selection IDs, whole/subset requests, Preview correlation/readiness, invalidation, cancellation/interruption and no Execute")
        for mode in ["no_changes", "attention"] {
            try write(mode, core.appendingPathComponent("mode")); model.refreshPreview(); await model.waitForCompletion()
            precondition(!model.canRebuild)
            model.requestRebuild(); precondition(model.state == .preview)
        }
        let outcomes: [(String, RestoreExecutionPresentation.Outcome)] = [
            ("execute_clean", .clean), ("execute_attention", .attention),
            ("execute_fail_before", .failedBeforeMutation), ("execute_fail_after", .failedAfterMutation),
            ("execute_stale", .failedBeforeMutation), ("execute_interrupted", .interrupted), ("execute_missing_result", .interrupted),
            ("execute_stop_before", .stoppedBeforeMutation), ("execute_stop_after", .stoppedAfterMutation)]
        for (mode, outcome) in outcomes {
            try write("clean", core.appendingPathComponent("mode")); model.refreshPreview(); await model.waitForCompletion()
            precondition(model.canRebuild)
            let id = model.preparation!.preparedPlanID
            model.requestRebuild(); precondition(model.state == .confirming && !runtime.isActive)
            model.cancelRebuildConfirmation(); precondition(model.canRebuild && model.preparation?.preparedPlanID == id)
            model.requestRebuild()
            try write(mode, core.appendingPathComponent("mode")); model.confirmRebuild()
            let operation = runtime.operationID
            model.confirmRebuild(); model.choose(source); model.back()
            precondition(runtime.operationID == operation && model.state == .rebuilding)
            if mode.hasPrefix("execute_stop") {
                for _ in 0..<100 { if runtime.currentPhase != nil { break }; try await Task.sleep(nanoseconds: 20_000_000) }
                model.requestStop()
                if mode == "execute_stop_after" {
                    precondition(model.stopConfirmation && model.mutationPossible)
                    model.stopConfirmation = false; precondition(runtime.isActive)
                    model.requestStop(); model.confirmStop()
                }
            }
            await model.waitForCompletion()
            precondition(model.state == .result && model.executionResult?.outcome == outcome)
            precondition(model.preparation == nil && !model.canRebuild)
            try write("clean", core.appendingPathComponent("mode")); model.checkCurrentState(); await model.waitForCompletion()
            precondition(model.state == .preview && model.canRebuild)
        }
        print("PASS: Stage 16G eligibility, confirmation, fine Execute request, ownership, zero-change, Safe Stop, failure/interruption and Verification outcomes; fixtures only")
        try await realPrepare(repo: repo, python: python, root: root)
    }

    @MainActor static func realPrepare(repo: URL, python: URL, root: URL) async throws {
        let setup = root.appendingPathComponent("setup.py")
        try write("""
        import sys, shutil
        from pathlib import Path
        repo=Path(sys.argv[1]); root=Path(sys.argv[2]); core=root/'real-core'; core.mkdir()
        shutil.copytree(repo/'modules',core/'modules'); shutil.copy2(repo/'bootstrap.sh',core/'bootstrap.sh')
        (core/'config').mkdir(); shutil.copy2(repo/'config/toolkit.conf',core/'config/toolkit.conf')
        home=root/'real-home'; home.mkdir(); tools=root/'tools'; tools.mkdir()
        for name,body in [('curl','exit 0'),('xcode-select','exit 0'),('sw_vers','echo 99'),('sudo','exit 99'),('age','exit 99')]:
            p=tools/name; p.write_text('#!/bin/bash\\n'+body+'\\n'); p.chmod(0o700)
        sys.path.insert(0,str(repo/'modules/bundle')); import bundle
        stage=root/'source'; stage.mkdir()
        flags={name:False for name in bundle.CATEGORY_FLAGS}
        raw='[categories]\\n'+''.join(name+'="false"\\n' for name in flags)
        raw+=''.join('\\n['+name+']\\n'+('Projects\\nOther\\n' if name=='workspace-folders' else '') for name in bundle.ITEMS)
        bundle.write_file(stage/'blueprint.conf',raw.encode())
        bundle.write_file(stage/'generated/workspace/folders.conf',b'Projects|workspace\\nOther|workspace\\n')
        bundle.pack(stage,root/'real.mbt','/Users/fixture-source')
        """, setup)
        let process = Process(); process.executableURL = python; process.arguments = ["-B", setup.path, repo.path, root.path]
        try process.run(); process.waitUntilExit(); precondition(process.terminationStatus == 0)
        let home = root.appendingPathComponent("real-home")
        let core = root.appendingPathComponent("real-core")
        let original = try Data(contentsOf: root.appendingPathComponent("real.mbt"))
        let runtime = CoreRuntime()
        let model = RestoreModel(runtime: runtime, location: CoreLocation(root: core, python: python, home: home, temporaryBase: root, toolDirectories: [root.appendingPathComponent("tools")]))
        model.choose(root.appendingPathComponent("real.mbt")); await model.waitForCompletion()
        precondition(model.state == .review, "Real inspection failed: \(model.failure ?? "")")
        model.toggleAll()
        let area = model.areas.first { $0.id == "workspace-folders" }!
        model.selectItem(area.id, item: area.items[1].id, included: true)
        model.refreshPreview(); await model.waitForCompletion()
        precondition(model.state == .preview && model.ready, "Real Prepare failed: \(model.failure ?? "")")
        precondition(model.preparation?.plan.count == 1 && model.preparation?.plan.first?.selectionItemID == area.items[1].id)
        precondition(model.preview?.categories.first?.items.first?.title == area.items[1].label)
        precondition(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Other").path))
        precondition(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Projects").path))
        precondition(!FileManager.default.fileExists(atPath: core.appendingPathComponent("config/generated").path))
        precondition(!FileManager.default.fileExists(atPath: core.appendingPathComponent("config/blueprint.conf").path))
        let after = try Data(contentsOf: root.appendingPathComponent("real.mbt"))
        precondition(after == original)
        precondition(runtime.operation == .restorePrepare)
        print("PASS: Swift → real bundle_inspect → stable subset → production Restore Preview, no target/config/Bundle mutation")
    }
}
