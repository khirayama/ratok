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

    var image: NSImage {
        let content = HStack(spacing: 8) {
            if providers.isEmpty {
                Text("Ratok")
            } else {
                ForEach(providers) { provider in
                    HStack(spacing: 4) {
                        Image(nsImage: provider.markImage).renderingMode(.template)
                            .resizable().scaledToFit().frame(width: 16, height: 16)
                        if store.showsMenuBarName(for: provider) {
                            Text(provider.menuBarName)
                        }
                        let values = store.menuBarValues(for: provider)
                        if !values.isEmpty {
                            Text(values.joined(separator: " ")).monospacedDigit()
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
