import AppKit
import SwiftUI
import UsageCore

extension Provider {
    var assetName: String { self == .claude ? "claude-mark" : "codex-mark" }
    var markImage: NSImage {
        guard let url = Bundle.module.url(forResource: assetName, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return NSImage(size: .zero) }
        image.isTemplate = true
        return image
    }
    var menuBarName: String { self == .claude ? "CC" : "Codex" }
}

struct MenuBarLabel: View {
    let store: UsageStore
    private let providers: [Provider] = [.codex, .claude]

    var body: some View {
        Image(nsImage: image)
            .accessibilityLabel(providers.map { store.menuHelp(for: $0) }.joined(separator: "、"))
            .help(providers.map { store.menuHelp(for: $0) }.joined(separator: "\n"))
    }

    private var image: NSImage {
        // MenuBarExtra flattens its label. Render both icons and values together
        // so each provider keeps its icon in the native status item.
        let content = HStack(spacing: 12) {
            ForEach(providers) { provider in
                HStack(spacing: 4) {
                    Image(systemName: provider.symbolName)
                    Text("\(provider.menuBarName) \(store.menuRemainingText(for: provider))")
                        .monospacedDigit()
                }
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.black)
        .fixedSize()
        .frame(height: 18)
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let cgImage = renderer.cgImage else { return NSImage(size: .zero) }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / renderer.scale,
                                                        height: CGFloat(cgImage.height) / renderer.scale))
        image.isTemplate = true
        return image
    }
}
