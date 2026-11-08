import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  private var quitting = false
  private var terminatePending = false

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // With the menu-bar icon the window only hides (no "close"), so this
    // fires only when the window really closes.
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if quitting {
      return .terminateNow
    }
    guard let window = MainFlutterWindow.shared, window.preventClose else {
      return .terminateNow
    }
    // Cmd+Q, logout, shutdown: let Dart stop the core and put the system
    // proxy back first; it answers with "quit".
    terminatePending = true
    window.notify("quitRequested")
    // Never hold up a logout or shutdown for long.
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
      if self?.terminatePending == true {
        self?.finishQuit()
      }
    }
    return .terminateLater
  }

  func finishQuit() {
    quitting = true
    if terminatePending {
      terminatePending = false
      NSApp.reply(toApplicationShouldTerminate: true)
    } else {
      NSApp.terminate(nil)
    }
  }

  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    // Dock icon clicked while the window is hidden in the menu bar.
    if !flag, let window = MainFlutterWindow.shared {
      window.showAndFocus()
      window.notify("activate")
    }
    return true
  }
}
