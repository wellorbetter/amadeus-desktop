import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var activityChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.isOpaque = false
    self.backgroundColor = .clear
    flutterViewController.backgroundColor = .clear

    RegisterGeneratedPlugins(registry: flutterViewController)

    activityChannel = FlutterMethodChannel(
      name: "amadeus/activity",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    activityChannel?.setMethodCallHandler { call, result in
      guard call.method == "getSnapshot" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let application = NSWorkspace.shared.frontmostApplication
      let idleEvents: [CGEventType] = [
        .keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel
      ]
      let idleSeconds = idleEvents
        .map {
          CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: $0)
        }
        .min() ?? 0
      result([
        "appName": application?.localizedName ?? "",
        "appId": application?.bundleIdentifier ?? "",
        "idleSeconds": Int(idleSeconds),
      ])
    }

    super.awakeFromNib()
  }
}
