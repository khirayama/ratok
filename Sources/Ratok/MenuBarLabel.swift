import AppKit
import SwiftUI
import UsageCore

extension Provider {
    private static var resourceBundle: Bundle {
        // Signed apps keep resources under Contents/Resources; swift run uses Bundle.module.
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Ratok_Ratok.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return .module
    }
    var assetName: String {
        switch self {
        case .claude: "claude-mark"
        case .codex: "codex-mark"
        case .openCodeGo: "opencode-mark"
        }
    }
    var markImage: NSImage {
        guard let url = Self.resourceBundle.url(forResource: assetName, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return NSImage(size: .zero) }
        image.isTemplate = true
        return image
    }
    var menuBarName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "ChatGPT"
        case .openCodeGo: "Go"
        }
    }
}

struct MenuBarLabel: View {
    let store: UsageStore
    private var providers: [Provider] { store.menuBarProviders }

    var body: some View {
        let help = providers.isEmpty
            ? "Ratok"
            : providers.map { store.menuHelp(for: $0) }.joined(separator: store.language == .japanese ? "、" : ", ")
        Image(nsImage: image)
            .accessibilityLabel(help)
            .help(help)
    }

    private struct Entry: Identifiable {
        let provider: Provider
        let showsName: Bool
        let values: [String]
        var id: Provider { provider }
    }

    var image: NSImage {
        // Read the store here, not inside the rendered view: ImageRenderer evaluates its content
        // outside this body, so reads there are not observed and settings changes would be missed.
        let entries = providers.map { provider in
            Entry(provider: provider, showsName: store.showsMenuBarName(for: provider),
                  values: store.menuBarValues(for: provider))
        }
        let content = HStack(spacing: 6) {
            if entries.isEmpty {
                Text("Ratok")
            } else {
                ForEach(entries) { entry in
                    HStack(spacing: 3) {
                        Image(nsImage: entry.provider.markImage).renderingMode(.template)
                            .resizable().scaledToFit().frame(width: 14, height: 14)
                        if entry.showsName {
                            Text(entry.provider.menuBarName)
                        }
                        if !entry.values.isEmpty {
                            Text(entry.values.joined(separator: " ")).monospacedDigit()
                        }
                    }
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
