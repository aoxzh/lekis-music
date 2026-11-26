import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    let appName =
      Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? "Lekis Music"
    if let appMenu = NSApp.mainMenu?.items.first?.submenu {
      appMenu.title = appName
      for item in appMenu.items where item.title.contains("APP_NAME") {
        item.title = item.title.replacingOccurrences(of: "APP_NAME", with: appName)
      }
    }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
