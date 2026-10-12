import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// "neforum/clipboard": puts a photo on the pasteboard for pasting into a
  /// web composer (lib/platform/clipboard_media.dart).
  private var clipboardChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "neforum/clipboard", binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "copyImage", let args = call.arguments as? [String: Any] else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(MainFlutterWindow.copyImage(args))
    }
    clipboardChannel = channel

    super.awakeFromNib()
  }

  /// PNG and TIFF (what browsers and apps read on paste) plus the original
  /// file's URL when `path` names a file.
  private static func copyImage(_ args: [String: Any]) -> Bool {
    let item = NSPasteboardItem()
    var any = false
    if let png = (args["png"] as? FlutterStandardTypedData)?.data, !png.isEmpty {
      any = item.setData(png, forType: .png) || any
      if let tiff = NSImage(data: png)?.tiffRepresentation {
        any = item.setData(tiff, forType: .tiff) || any
      }
    }
    if let path = args["path"] as? String, !path.isEmpty, FileManager.default.fileExists(atPath: path) {
      any = item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL) || any
    }
    guard any else { return false }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    return pasteboard.writeObjects([item])
  }
}
