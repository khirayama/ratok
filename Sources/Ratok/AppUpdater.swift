import Combine
import Foundation
import Sparkle

/// One updater for the lifetime of the app; command line modes never create it.
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates = false {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }
    @Published var automaticallyDownloadsUpdates = false {
        didSet { controller?.updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates }
    }
    let configurationMessage: String?
    var isConfigured: Bool { controller != nil }
    private let controller: SPUStandardUpdaterController?

    init(enabled: Bool = true) {
        let bundle = Bundle.main
        guard enabled, bundle.bundleURL.pathExtension == "app" else {
            controller = nil
            configurationMessage = "この起動方法では更新を利用できません"
            return
        }
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            controller = nil
            configurationMessage = "更新の配布先が未設定です"
            return
        }
        configurationMessage = nil
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.startUpdater()
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = controller.updater.automaticallyDownloadsUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }
}
