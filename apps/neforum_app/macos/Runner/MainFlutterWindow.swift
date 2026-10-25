import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// "neforum/clipboard": puts a photo on the pasteboard for pasting into a
  /// web composer (lib/platform/clipboard_media.dart).
  private var clipboardChannel: FlutterMethodChannel?

  /// "neforum/bookmarks": keeps the sync folder the user picked reachable
  /// after a restart, through a security-scoped bookmark
  /// (lib/platform/folder_access.dart).
  private var bookmarksChannel: FlutterMethodChannel?

  /// Folders reopened from a bookmark stay open until NEFORUM quits.
  private static var openFolders: [URL] = []

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    VideoCompositorPlugin.register(with: flutterViewController.registrar(forPlugin: "NeforumVideoCompositor"))

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

    let bookmarks = FlutterMethodChannel(
      name: "neforum/bookmarks", binaryMessenger: flutterViewController.engine.binaryMessenger)
    bookmarks.setMethodCallHandler { call, result in
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterMethodNotImplemented)
        return
      }
      switch call.method {
      case "save":
        result(MainFlutterWindow.saveBookmark(args["path"] as? String))
      case "open":
        result(MainFlutterWindow.openBookmark(args["bookmark"] as? String))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    bookmarksChannel = bookmarks

    super.awakeFromNib()
  }

  /// A security-scoped bookmark of the folder at `path`, base64.
  private static func saveBookmark(_ path: String?) -> String? {
    guard let path = path else { return nil }
    do {
      let data = try URL(fileURLWithPath: path, isDirectory: true).bookmarkData(
        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
      return data.base64EncodedString()
    } catch {
      return nil
    }
  }

  /// Resolves a bookmark from `saveBookmark` and opens the folder; returns
  /// its path.
  private static func openBookmark(_ bookmark: String?) -> String? {
    guard let bookmark = bookmark, let data = Data(base64Encoded: bookmark) else { return nil }
    var stale = false
    do {
      let url = try URL(
        resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
      guard url.startAccessingSecurityScopedResource() else { return nil }
      openFolders.append(url)
      return url.path
    } catch {
      return nil
    }
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
