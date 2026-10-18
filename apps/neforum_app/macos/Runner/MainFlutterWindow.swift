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
      if call.method == "readImage" {
        result(MainFlutterWindow.readImage())
        return
      }
      guard call.method == "copyImage", let args = call.arguments as? [String: Any] else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(MainFlutterWindow.copyImage(args))
    }
    clipboardChannel = channel

    super.awakeFromNib()
  }

  /// What a paste into the composer can attach: copied files (Finder), else a
  /// picture as PNG (TIFF from screenshots and apps is converted). Empty when
  /// the pasteboard holds neither.
  private static func readImage() -> [String: Any] {
    let pasteboard = NSPasteboard.general
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
       !urls.isEmpty {
      return ["files": urls.map { $0.path }]
    }
    if let png = pasteboard.data(forType: .png), !png.isEmpty {
      return ["png": FlutterStandardTypedData(bytes: png)]
    }
    if let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
      return ["png": FlutterStandardTypedData(bytes: png)]
    }
    return [:]
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
