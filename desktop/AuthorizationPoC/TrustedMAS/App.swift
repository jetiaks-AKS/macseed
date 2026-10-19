import AppKit
import Foundation
import ServiceManagement
import Darwin

enum Client {
    static func call(_ operation: String) -> String {
        guard Contract.operations.union(["preflight", "install", "reconcile", "observe-processes", "lifetime-version", "lifetime-status"]).contains(operation) else { return "invalid_operation" }
        let connection = NSXPCConnection(machServiceName: Contract.helper, options: .privileged)
        connection.setCodeSigningRequirement(Contract.requirement(Contract.helper))
        connection.remoteObjectInterface = NSXPCInterface(with: MASDiagnostics.self)
        let lock = NSLock(); var result: String?
        func finish(_ text: String) { lock.lock(); defer { lock.unlock() }; if result == nil { result = text } }
        connection.invalidationHandler = { finish("connection_invalidated") }
        connection.interruptionHandler = { finish("connection_interrupted") }
        connection.resume()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in finish("connection_failed") } as? MASDiagnostics
        switch operation {
        case "lifetime-version": proxy?.qualifyLifetimeVersion { finish($0) }
        case "lifetime-status": proxy?.lifetimeQualificationStatus { finish($0) }
        case "observe-processes": proxy?.observeProcesses { finish($0) }
        case "preflight": proxy?.preflight(Contract.targetID) { finish($0) }
        case "install": proxy?.install(Contract.targetID, confirmed: true) { finish($0) }
        case "reconcile": proxy?.reconcileLegacyDiagnostic(true) { finish($0) }
        default: proxy?.perform(operation) { finish($0) }
        }
        let deadline = Date().addingTimeInterval(operation == "install" ? 990 : 40)
        while Date() < deadline {
            lock.lock(); let done = result != nil; lock.unlock()
            if done { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        lock.lock(); let text = result ?? "client_timeout_unknown_no_retry"; lock.unlock()
        connection.invalidate(); return text
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let result = NSTextField(wrappingLabelWithString: "Controlled Blackmagic test: ID 425264550; separate v5 journal; no retry after unknown.")
    let service = SMAppService.daemon(plistName: Contract.helper + ".plist")
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 580), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Macseed — Trusted MAS Deployment PoC"
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.addArrangedSubview(result)
        for (title, selector) in [("Register helper", #selector(register)), ("System approval settings", #selector(settings)), ("Preflight", #selector(preflight)), ("Install Blackmagic (test)", #selector(install)), ("Operation Status", #selector(lifetimeStatus)), ("Verification (user inventory + bundle)", #selector(verification)), ("Unregister helper", #selector(unregister))] {
            let button = NSButton(title: title, target: self, action: selector)
            if selector == #selector(install) { button.isEnabled = Contract.liveInstallEnabled }
            stack.addArrangedSubview(button)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20)])
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func lifetimeVersion() { result.stringValue = Client.call("lifetime-version") }
    @objc func lifetimeStatus() { result.stringValue = Client.call("lifetime-status") }
    @objc func register() { do { try service.register(); result.stringValue = "registered status=\(service.status.rawValue)" } catch { let e = error as NSError; result.stringValue = "\(e.domain)/\(e.code) status=\(service.status.rawValue)" } }
    @objc func unregister() { do { try service.unregister(); result.stringValue = "unregistered status=\(service.status.rawValue)" } catch { let e = error as NSError; result.stringValue = "\(e.domain)/\(e.code)" } }
    @objc func settings() { SMAppService.openSystemSettingsLoginItems() }
    @objc func observeProcesses() { result.stringValue = Client.call("observe-processes") }
    @objc func reconcile() {
        let alert = NSAlert()
        alert.messageText = "Reconcile legacy diagnostic unknown?"
        alert.informativeText = "Confirm that this fixed legacy journal belongs to the documented list interruption test. The original and evidence will be archived. Historical operation/child identity remains unknown; Apple service quiescence is not established. Uncertain attribution must be cancelled."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Record operator decision")
        if alert.runModal() == .alertSecondButtonReturn { result.stringValue = Client.call("reconcile") }
    }
    @objc func verification() { result.stringValue = UserVerification.run() }
    @objc func preflight() { result.stringValue = Client.call("preflight") }
    @objc func install() {
        guard Contract.liveInstallEnabled else { result.stringValue = "Live install disabled; separate permission and qualified deployment required."; return }
        let alert = NSAlert(); alert.messageText = "Install Blackmagic Disk Speed Test (425264550)?"
        alert.informativeText = "One controlled install only. No force/reinstall. App Store account and GUI bootstrap compatibility remain experimental. Timeout/disconnect retains unknown without retry."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Install selected app")
        if alert.runModal() == .alertSecondButtonReturn { result.stringValue = Client.call("install") }
    }
    @objc func deploy() { result.stringValue = Client.call("deploy") }
    @objc func version() { result.stringValue = Client.call("version") }
    @objc func list() { result.stringValue = Client.call("list") }
    @objc func state() { result.stringValue = Client.call("state") }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main enum Main {
    static func main() {
        if CommandLine.arguments.count == 2 {
            let operation = CommandLine.arguments[1]
            guard Set(["lifetime-version", "lifetime-status"]).contains(operation) else { exit(64) }
            print(Client.call(operation)); return
        }
        guard CommandLine.arguments.count == 1 else { exit(64) }
        let app = NSApplication.shared; let delegate = Delegate()
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
