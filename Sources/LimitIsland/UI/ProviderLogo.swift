import AppKit
import SwiftUI

/// Loads the supplied PNG directly from the Swift Package resource bundle.
/// `Image(name:bundle:)` can silently fall back to an empty image for package
/// resources in an AppKit-hosted status window, so use the concrete NSImage.
struct ProviderLogo: View {
    let provider: Provider
    var size: CGFloat

    private var image: NSImage? { Self.cache[provider] ?? nil }

    /// Decoded once per provider. The strip alternates between percentage and
    /// countdown every few seconds, so a computed property here re-read and
    /// re-decoded every logo from disk several times a minute, per meter.
    private static let cache: [Provider: NSImage?] = Dictionary(
        uniqueKeysWithValues: Provider.allCases.map { provider in
            let image = Bundle.module
                .url(forResource: provider.assetName, withExtension: "png")
                .flatMap(NSImage.init(contentsOf:))
            if image == nil {
                Log.window.error("missing bundled logo \(provider.assetName, privacy: .public).png")
            }
            return (provider, image)
        }
    )

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: provider.fallbackSymbol)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(provider.color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(provider.title)
    }
}
