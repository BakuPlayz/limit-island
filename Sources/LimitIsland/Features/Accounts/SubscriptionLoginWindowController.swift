import AppKit
import WebKit

/// A standard keyable AppKit window for provider authentication. Unlike a
/// MenuBarExtra sheet, this becomes the active window and WebKit receives text
/// input normally while retaining its provider-specific website data store.
@MainActor
final class SubscriptionLoginWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private let meter: Meter
    private let webView: WKWebView
    private let window: NSWindow
    private var popupWindows: [ObjectIdentifier: NSWindow] = [:]
    /// Lets the owner drop its reference when the user closes the window. The
    /// window is `isReleasedWhenClosed = false`, so without this the window, its
    /// web view and every OAuth popup it spawned lived until the app quit.
    var onClose: (() -> Void)?

    init(meter: Meter, webView: WKWebView) {
        self.meter = meter
        self.webView = webView
        self.window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "\(meter.displayLabel) — \(meter.provider.title)"
        window.minSize = NSSize(width: 640, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.contentView = webView
    }

    func show() {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window.makeFirstResponder(self.webView)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window.makeFirstResponder(webView)
    }

    func windowWillClose(_ notification: Notification) {
        closePopups()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        onClose?()
    }

    /// WebKit asks to close a popup once OAuth finishes.
    func webViewDidClose(_ webView: WKWebView) {
        dismissPopup(ObjectIdentifier(webView))
    }

    private func closePopups() {
        for identifier in popupWindows.keys { dismissPopup(identifier) }
    }

    private func dismissPopup(_ identifier: ObjectIdentifier) {
        guard let popup = popupWindows.removeValue(forKey: identifier) else { return }
        window.removeChildWindow(popup)
        popup.contentView = nil
        popup.orderOut(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView !== self.webView else {
            window.makeFirstResponder(webView)
            return
        }

        // Google returns to claude.ai after the account is selected. Hide the
        // OAuth child shortly after that navigation finishes; hiding avoids
        // racing WebKit's own close callback.
        guard let host = webView.url?.host, host.hasSuffix(meter.provider.signInReturnHost) else { return }
        let identifier = ObjectIdentifier(webView)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.dismissPopup(identifier)
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Google sign-in is launched as a popup. Keeping it in the original
        // page blanks Claude's WebKit view; a real child window lets OAuth
        // complete and shares the same persistent provider data store.
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.customUserAgent = webView.customUserAgent
        popup.navigationDelegate = self
        popup.uiDelegate = self

        let popupWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        popupWindow.title = "Sign in to \(meter.provider.title)"
        popupWindow.contentView = popup
        popupWindows[ObjectIdentifier(popup)] = popupWindow
        window.addChildWindow(popupWindow, ordered: .above)
        popupWindow.center()
        popupWindow.makeKeyAndOrderFront(nil)
        return popup
    }

}
