import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AppearanceStore {
    static let shared = AppearanceStore()

    private static let defaultsKey = "limit-island.font-family"
    var selectedFamily: String? {
        didSet {
            if let selectedFamily {
                UserDefaults.standard.set(selectedFamily, forKey: Self.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
            }
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.defaultsKey)
        selectedFamily = saved.flatMap { NSFontManager.shared.availableFontFamilies.contains($0) ? $0 : nil }
    }

    var systemFamily: String { NSFont.systemFont(ofSize: NSFont.systemFontSize).familyName ?? "San Francisco" }
    var availableFamilies: [String] { NSFontManager.shared.availableFontFamilies.sorted() }

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard let selectedFamily else { return .system(size: size, weight: weight) }
        return .custom(selectedFamily, size: size).weight(weight)
    }
}

private struct IslandFontModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    @State private var appearance = AppearanceStore.shared

    func body(content: Content) -> some View {
        content.font(appearance.font(size: size, weight: weight))
    }
}

extension View {
    func islandFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(IslandFontModifier(size: size, weight: weight))
    }
}
