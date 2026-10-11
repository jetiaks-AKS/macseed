import AppKit
import SwiftUI

// Compile with Sources/Branding.swift, ContentView.swift and its UI dependencies,
// or use generate-app-icon.sh, which supplies the same production sources.
@main struct GenerateAppIcon {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let assets = root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset")
        let entries = try JSONSerialization.jsonObject(with: Data(contentsOf: assets.appendingPathComponent("Contents.json"))) as! [String: Any]
        let iconset = root.appendingPathComponent("build/Branding/Macseed.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for entry in entries["images"] as! [[String: String]] {
            let width = Int(entry["size"]!.split(separator: "x")[0])! * Int(entry["scale"]!.dropLast())!
            let renderer = ImageRenderer(content: MacseedAppIcon().frame(width: CGFloat(width), height: CGFloat(width)).environment(\.colorScheme, .light))
            renderer.scale = 1
            guard let cgImage = renderer.cgImage else { fatalError("Cannot render app icon") }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            let data = bitmap.representation(using: .png, properties: [:])!
            try data.write(to: assets.appendingPathComponent(entry["filename"]!))
            try data.write(to: iconset.appendingPathComponent(entry["filename"]!))
        }
    }
}
