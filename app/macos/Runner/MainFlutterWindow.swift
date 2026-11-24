import Cocoa
import FlutterMacOS
import WebKit

class MainFlutterWindow: NSWindow {
  private var videoChannel: FlutterMethodChannel?
  private let videoPlayer = VideoPlayerWindow()

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "dev.lekis/video",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "open" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self = self else {
        result(FlutterError(code: "closed", message: "Player host closed", details: nil))
        return
      }
      self.videoPlayer.open(arguments: call.arguments, result: result)
    }
    videoChannel = channel
    let center = NotificationCenter.default
    center.addObserver(self, selector: #selector(closeVideo), name: NSWindow.willCloseNotification,
                       object: self)
    center.addObserver(self, selector: #selector(closeVideo), name: NSApplication.willTerminateNotification,
                       object: NSApp)
    super.awakeFromNib()
  }

  @objc private func closeVideo() {
    videoPlayer.close()
  }
}

private final class VideoPlayerWindow: NSObject, NSWindowDelegate, WKNavigationDelegate {
  private var window: NSWindow?
  private var webView: WKWebView?
  private var target: URL?
  private var pending: FlutterResult?
  private var deadline: Timer?

  private static func playerURL(_ arguments: Any?) -> URL? {
    guard let args = arguments as? [String: Any],
          let raw = args["url"] as? String
    else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.utf8.count <= 4096,
          let components = URLComponents(string: trimmed),
          components.scheme == "https",
          let host = components.host, !host.isEmpty,
          components.user == nil, components.password == nil,
          let url = components.url
    else { return nil }
    return url
  }

  func open(arguments: Any?, result: @escaping FlutterResult) {
    guard let url = Self.playerURL(arguments) else {
      result(FlutterError(code: "invalid_args", message: "Expected an HTTPS page URL", details: nil))
      return
    }
    clearPlayer(reason: "replaced")
    let config = WKWebViewConfiguration()
    if #available(macOS 12.3, *) {
      config.preferences.isElementFullscreenEnabled = true
    }
    let view = WKWebView(frame: .zero, configuration: config)
    let playerWindow: NSWindow
    if let existing = window {
      playerWindow = existing
    } else {
      playerWindow = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 854, height: 480),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false)
      playerWindow.title = (arguments as? [String: Any])?["title"] as? String ?? "Lekis · 视频"
      playerWindow.isReleasedWhenClosed = false
      playerWindow.collectionBehavior.insert(.fullScreenPrimary)
      playerWindow.delegate = self
      playerWindow.center()
      window = playerWindow
    }
    playerWindow.title = (arguments as? [String: Any])?["title"] as? String ?? "Lekis · 视频"
    target = url
    pending = result
    webView = view
    view.navigationDelegate = self
    playerWindow.contentView = view
    if playerWindow.isMiniaturized { playerWindow.deminiaturize(nil) }
    playerWindow.makeKeyAndOrderFront(nil)
    deadline = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self, weak view] _ in
      guard let self = self, let view = view, self.webView === view else { return }
      self.fail("timeout", "Player page timed out")
    }
    view.load(URLRequest(url: url))
  }

  func close() {
    window?.close()
  }

  func windowWillClose(_ notification: Notification) {
    clearPlayer(reason: "closed")
    window = nil
  }

  private func finish(_ error: FlutterError?) {
    deadline?.invalidate()
    deadline = nil
    let reply = pending
    pending = nil
    reply?(error)
  }

  private func clearPlayer(reason: String) {
    let old = webView
    webView = nil
    target = nil
    old?.navigationDelegate = nil
    old?.setAllMediaPlaybackSuspended(true, completionHandler: nil)
    old?.closeAllMediaPresentations(completionHandler: nil)
    old?.stopLoading()
    old?.removeFromSuperview()
    window?.contentView = nil
    finish(FlutterError(code: reason, message: "Player \(reason)", details: nil))
  }

  private func fail(_ code: String, _ message: String) {
    finish(FlutterError(code: code, message: message, details: nil))
    close()
  }

  func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    let allowed = view === webView && action.targetFrame?.isMainFrame == true
      && !action.shouldPerformDownload && action.request.url == target
    decisionHandler(allowed ? .allow : .cancel)
  }

  func webView(_ view: WKWebView, decidePolicyFor response: WKNavigationResponse,
               decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    let http = response.response as? HTTPURLResponse
    let allowed = view === webView && response.isForMainFrame && response.response.url == target
      && http.map { (200..<300).contains($0.statusCode) } == true
      && response.response.mimeType == "text/html" && response.canShowMIMEType
    decisionHandler(allowed ? .allow : .cancel)
    if !allowed && view === webView && response.isForMainFrame {
      fail("load_failed", "Official player page unavailable")
    }
  }

  func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
    guard view === webView, view.url == target, let window = window else { return }
    window.displayIfNeeded()
    finish(nil)
  }

  func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
               withError error: Error) {
    if view === webView { fail("load_failed", error.localizedDescription) }
  }

  func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    if view === webView { fail("load_failed", error.localizedDescription) }
  }

  func webViewWebContentProcessDidTerminate(_ view: WKWebView) {
    if view === webView { fail("player_terminated", "Web content process exited") }
  }
}
