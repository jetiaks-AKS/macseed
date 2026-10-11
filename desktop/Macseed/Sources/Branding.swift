import SwiftUI

// Shared vector silhouette for the UI and all exported app-icon sizes.
struct MacseedLeaf: Shape {
    var folded = false
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        p.move(to: point(0.12, 0.90))
        if folded {
            p.addCurve(to: point(0.89, 0.10), control1: point(0.40, 0.39), control2: point(0.81, 0.51))
            p.addCurve(to: point(0.57, 0.80), control1: point(0.91, 0.51), control2: point(0.83, 0.78))
            p.addCurve(to: point(0.12, 0.90), control1: point(0.33, 0.83), control2: point(0.21, 0.80))
        } else {
            p.addCurve(to: point(0.89, 0.10), control1: point(0.02, 0.20), control2: point(0.60, 0.23))
            p.addCurve(to: point(0.57, 0.80), control1: point(0.91, 0.51), control2: point(0.83, 0.78))
            p.addCurve(to: point(0.12, 0.90), control1: point(0.33, 0.83), control2: point(0.21, 0.80))
        }
        p.closeSubpath()
        return p
    }
}

struct MacseedBrandMark: View {
    var body: some View {
        ZStack {
            MacseedLeaf().fill(LinearGradient(colors: [Color(red: 0.16, green: 0.59, blue: 1), Color(red: 0.27, green: 0.27, blue: 0.94)], startPoint: .topLeading, endPoint: .bottomTrailing))
            MacseedLeaf(folded: true).fill(LinearGradient(colors: [Color(red: 0.65, green: 0.41, blue: 1), Color(red: 0.29, green: 0.39, blue: 0.98)], startPoint: .topTrailing, endPoint: .bottomLeading))
        }.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
    }
}

struct MacseedAppIcon: View {
    var body: some View {
        ZStack {
            GeometryReader { geometry in
                let size = geometry.size.width
                RoundedRectangle(cornerRadius: size * 0.20)
                    .fill(LinearGradient(colors: [.white, Color(red: 0.73, green: 0.82, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.20).strokeBorder(.white.opacity(0.85), lineWidth: max(1, size * 0.003)))
                    .overlay(MacseedBrandMark().padding(size * 0.21))
                    .padding(size * 0.065)
            }
        }
    }
}

struct MacseedHomeHero: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 24) {
            MacseedAppIcon().frame(width: 112, height: 112)
            VStack(alignment: .leading, spacing: 10) {
                Text("Macseed").font(.system(size: 40, weight: .bold))
                Text("Capture your environment. Rebuild with confidence.").font(.title3).foregroundStyle(.secondary)
            }
        }.padding(32).frame(maxWidth: .infinity, minHeight: 210, alignment: .leading)
            .background(LinearGradient(colors: scheme == .dark
                ? [Color(red: 0.15, green: 0.25, blue: 0.40), Color(red: 0.28, green: 0.22, blue: 0.43)]
                : [Color(red: 0.80, green: 0.91, blue: 1), Color(red: 0.85, green: 0.82, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20))
    }
}

struct MacseedTaskLabel: View {
    let task: ProductTask
    var body: some View {
        Label { Text(task.rawValue) } icon: {
            Image(systemName: task.symbol).foregroundStyle(WorkspaceIdentity.tint(task))
        }
    }
}

struct MacseedSidebarBrand: View {
    var body: some View {
        HStack(spacing: 10) {
            MacseedBrandMark().frame(width: 28, height: 28)
            Text("Macseed").font(.title3.weight(.semibold))
        }.padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 8)
    }
}
