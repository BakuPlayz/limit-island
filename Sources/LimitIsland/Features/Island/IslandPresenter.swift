import AppKit
import Observation
import SwiftUI

/// Everything the notch content needs that is not in one of the stores: which
/// presentation it is in, and the geometry of the display it is on.
///
/// This type exists because of a crash. `IslandWindowController` used to pass these
/// as `let` properties and rebuild the whole `NSHostingView` whenever one changed —
/// including from inside `.onHover`, which runs during AppKit's layout pass, so the
/// hover callback destroyed the view tree that was calling it. Holding them in an
/// `@Observable` means SwiftUI re-renders in place and the view hierarchy is built
/// exactly once, at launch.
@MainActor
@Observable
final class IslandPresenter {
    enum JumpSheet: Equatable {
        case chooser(sessionID: String, destinations: [TerminalDestination])
        case automation(sessionID: String, terminal: String)
        case setup(sessionID: String, terminal: String)
        case notice(String)
    }

    var presentation: IslandPresentation = .strip
    var jumpSheet: JumpSheet?
    var questionShortcut: ((Int) -> Void)?
    /// True while a card is showing a text field. The window controller watches this
    /// to lend the panel keyboard focus for exactly that long — see `NeverKeyPanel`.
    var isComposing = false
    /// Ideal height of the active interaction, measured by SwiftUI after layout.
    var interactionHeight: CGFloat = 0

    /// Width of the physical camera housing on the active display.
    var notchWidth: CGFloat = 0
    /// Height of the camera housing. The expanded panel reserves this much at the
    /// top so nothing is ever drawn behind it.
    var notchHeight: CGFloat = NotchLayout.minimumHeaderHeight

    /// Measured widths of the two strip sides, already clamped to the space
    /// actually available beside the notch.
    var leftWidth: CGFloat = 0
    var rightWidth: CGFloat = 0

    /// Read in the panel's empty state. Kept here rather than called from a view
    /// body, where it was reading `~/.claude/settings.json` on every render.
    var hookState: HookInstaller.State = .absent

    /// The top band of the expanded panel is at least as tall as the housing, so
    /// the divider below it clears the notch on every display.
    var headerHeight: CGFloat {
        max(NotchLayout.minimumHeaderHeight, notchHeight)
    }

    func refreshHookState() {
        let state = HookInstaller.state()
        if hookState != state { hookState = state }
    }

    /// Assigns only on a real change.
    ///
    /// `@Observable` notifies on every `set`, equal or not, and the controller
    /// recomputes all of these whenever a session event arrives. Without the guard,
    /// a session merely changing its activity would re-render the whole notch.
    func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<IslandPresenter, Value>, to value: Value) {
        guard self[keyPath: keyPath] != value else { return }
        self[keyPath: keyPath] = value
    }
}
