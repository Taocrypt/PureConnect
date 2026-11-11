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

  /// Hosts the Flutter view over an NSVisualEffectView for the sidebar blur
  /// (FlClash's WindowEffectView, MIT); inactive until Dart turns it on.
  private var effectHost: EffectHostViewController?
  private var flutterController: FlutterViewController?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    flutterController = flutterViewController
    let windowFrame = self.frame
    let host = EffectHostViewController(hosting: flutterViewController)
    self.contentViewController = host
    // macOS 12 detaches the outgoing controller's view only after loading the
    // host, by then from the effect view, which leaves the window blank.
    host.attachFlutterView()
    effectHost = host
    self.setFrame(windowFrame, display: true)
    self.minSize = NSSize(width: 380, height: 400)

    // Immersive frame (FlClash): macOS 11+ keeps the traffic lights over a
    // transparent, full-size title bar; the content runs under it.
    if #available(macOS 11.0, *) {
      self.titleVisibility = .hidden
      self.titlebarAppearsTransparent = true
      self.styleMask.insert(.fullSizeContentView)
    }

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
      case "minimize":
        self.miniaturize(nil)
        result(true)
      case "maximize":
        if !self.isZoomed { self.zoom(nil) }
        result(true)
      case "unmaximize":
        if self.isZoomed { self.zoom(nil) }
        result(true)
      case "isMaximized":
        result(self.isZoomed)
      case "startDragging":
        if let event = NSApp.currentEvent {
          self.performDrag(with: event)
        }
        result(true)
      case "setAlwaysOnTop":
        let on = call.arguments as? Bool ?? false
        self.level = on ? .floating : .normal
        result(true)
      case "isAlwaysOnTop":
        result(self.level == .floating)
      case "setEffect":
        let args = call.arguments as? [String: Any] ?? [:]
        let enabled = args["enabled"] as? Bool ?? false
        let dark = args["dark"] as? Bool ?? false
        self.applyBlur(enabled: enabled, dark: dark)
        result(enabled)
      case "systemAccent":
        if let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
          let a = 255, r = Int(c.redComponent * 255), g = Int(c.greenComponent * 255), b = Int(c.blueComponent * 255)
          result((a << 24) | (r << 16) | (g << 8) | b)
        } else {
          result(nil)
        }
      case "launchArgs":
        result(Array(CommandLine.arguments.dropFirst()))
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

  /// Sidebar blur: the .sidebar material behind a transparent Flutter view.
  func applyBlur(enabled: Bool, dark: Bool) {
    guard let host = effectHost, let flutter = flutterController else { return }
    let effectView = host.effectView
    if enabled {
      effectView.maskImage = nil
      effectView.material = .sidebar
      effectView.state = .followsWindowActiveState
      effectView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      flutter.backgroundColor = .clear
      self.isOpaque = false
      self.backgroundColor = .clear
    } else {
      effectView.maskImage = NSImage()
      effectView.state = .inactive
      flutter.backgroundColor = .windowBackgroundColor
      self.isOpaque = true
      self.backgroundColor = .windowBackgroundColor
    }
    self.hasShadow = true
  }

  func notify(_ method: String) {
    windowChannel?.invokeMethod(method, arguments: nil)
  }

  func windowDidMiniaturize(_ notification: Notification) {
    // Dart hides the window to the menu bar when "minimise to tray" is on.
    notify("minimized")
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if preventClose {
      notify("close")
      return false
    }
    return true
  }
}

/// The Flutter view over an NSVisualEffectView (FlClash's
/// EffectHostViewController, MIT).
final class EffectHostViewController: NSViewController {
  let flutterViewController: FlutterViewController
  let effectView = NSVisualEffectView()

  init(hosting flutterViewController: FlutterViewController) {
    self.flutterViewController = flutterViewController
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    nil
  }

  override func loadView() {
    effectView.frame = flutterViewController.view.frame
    effectView.autoresizingMask = [.width, .height]
    effectView.blendingMode = .behindWindow
    effectView.state = .inactive
    effectView.maskImage = NSImage()
    addChild(flutterViewController)
    attachFlutterView()
    view = effectView
  }

  func attachFlutterView() {
    let flutterView = flutterViewController.view
    guard flutterView.superview !== effectView else { return }
    flutterView.translatesAutoresizingMaskIntoConstraints = true
    flutterView.frame = effectView.bounds
    flutterView.autoresizingMask = [.width, .height]
    effectView.addSubview(flutterView)
  }
}
