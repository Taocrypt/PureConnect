import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  /// Launched at login with --hidden ("start minimised"): keep the window
  /// off screen until Dart calls "show" (tray, Dock click or second launch).
  static var holdHidden = CommandLine.arguments.contains("--hidden")
  static weak var shared: MainFlutterWindow?

  private var windowChannel: FlutterMethodChannel?
  /// Set by Dart once it handles "close": the red button then goes to Dart,
  /// which hides to the menu bar or cleans up and calls "quit".
  var preventClose = false

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // "pureconnect/window": setIcon(<absolute png path>) swaps the Dock icon
    // while the app runs; an empty path restores the bundle icon (a1).
    // Finder/Launchpad keep the bundle icon: rewriting the .app would break
    // its code signature. show / hide / isVisible / setPreventClose / quit /
    // setDockIconVisible drive the menu-bar (tray) behaviour.
    let channel = FlutterMethodChannel(
      name: "pureconnect/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(false)
        return
      }
      switch call.method {
      case "setIcon":
        let path = call.arguments as? String ?? ""
        if path.isEmpty {
          NSApp.applicationIconImage = nil
          result(true)
        } else if let image = NSImage(contentsOfFile: path) {
          NSApp.applicationIconImage = image
          result(true)
        } else {
          result(false)
        }
      case "show":
        self.showAndFocus()
        result(true)
      case "hide":
        self.orderOut(nil)
        result(true)
      case "isVisible":
        result(self.isVisible)
      case "setPreventClose":
        self.preventClose = call.arguments as? Bool ?? false
        result(true)
      case "quit":
        self.preventClose = false
        result(true)
        DispatchQueue.main.async {
          (NSApp.delegate as? AppDelegate)?.finishQuit()
        }
      case "setDockIconVisible":
        let visible = call.arguments as? Bool ?? true
        NSApp.setActivationPolicy(visible ? .regular : .accessory)
        if visible && self.isVisible {
          NSApp.activate(ignoringOtherApps: true)
        }
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    windowChannel = channel
    MainFlutterWindow.shared = self
    self.delegate = self

    super.awakeFromNib()
    if MainFlutterWindow.holdHidden {
      DispatchQueue.main.async { self.orderOut(nil) }
    }
  }

  override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    if MainFlutterWindow.holdHidden && place != .out {
      return
    }
    super.order(place, relativeTo: otherWin)
  }

  func showAndFocus() {
    MainFlutterWindow.holdHidden = false
    if isMiniaturized {
      deminiaturize(nil)
    }
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
  }

  func notify(_ method: String) {
    windowChannel?.invokeMethod(method, arguments: nil)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if preventClose {
      notify("close")
      return false
    }
    return true
  }
}
