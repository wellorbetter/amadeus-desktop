import Cocoa
import FlutterMacOS

@_silgen_name("amadeus_core_version")
private func amadeusCoreVersion() -> UInt32

@_silgen_name("amadeus_activity_classify")
private func amadeusActivityClassify(
  _ appName: UnsafePointer<CChar>,
  _ idleSeconds: UInt64,
  _ idleThreshold: UInt64,
  _ excludedApps: UnsafePointer<CChar>
) -> Int32

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
      let arguments = call.arguments as? [String: Any]
      let idleThreshold = max(arguments?["idleThreshold"] as? Int ?? 300, 1)
      let exclusions = (arguments?["excludedApps"] as? [String] ?? [])
        .joined(separator: "\n")
      let appName = application?.localizedName ?? ""
      let decision = appName.withCString { appNamePointer in
        exclusions.withCString { exclusionsPointer in
          amadeusActivityClassify(
            appNamePointer,
            UInt64(max(idleSeconds, 0)),
            UInt64(idleThreshold),
            exclusionsPointer)
        }
      }
      result([
        "appName": appName,
        "appId": application?.bundleIdentifier ?? "",
        "idleSeconds": Int(idleSeconds),
        "decision": Int(decision),
        "coreVersion": Int(amadeusCoreVersion()),
      ])
    }

    super.awakeFromNib()
  }
}
