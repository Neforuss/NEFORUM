import Flutter
import UIKit
import UniformTypeIdentifiers
import UserNotifications
import flutter_local_notifications
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Must match kPublishDueTask in lib/state/scheduler.dart and
  /// BGTaskSchedulerPermittedIdentifiers in Info.plist.
  static let publishDueTask = "org.neforum.publish_due"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Background publishing: plugins must be available in the headless
    // engine WorkManager starts for BGTaskScheduler runs.
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
      SyncFolderPlugin.register(in: registry)
    }
    // Same for the isolate that runs "Publish now" on a due-post reminder.
    FlutterLocalNotificationsPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
      SyncFolderPlugin.register(in: registry)
    }
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: AppDelegate.publishDueTask,
      earliestBeginInSeconds: NSNumber(value: 15 * 60)
    )
    // UIScene apps must re-register launch handlers before returning.
    WorkmanagerPlugin.registerLaunchHandlers()

    // Show "time to post" reminders even while NEFORUM is open.
    UNUserNotificationCenter.current().delegate = self

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    SyncFolderPlugin.register(in: engineBridge.pluginRegistry)
  }
}

/// A failure with a code the Dart side understands ("conflict").
struct SyncFolderError: Error {
  let code: String
  let message: String
}

/// "neforum/syncfolder": the sync file in a folder the user picked in the
/// Files app (iCloud Drive, or the location of a cloud app such as OneDrive,
/// Google Drive or Dropbox). Access survives restarts through a bookmark,
/// and every read and write goes through NSFileCoordinator, so iCloud or the
/// cloud app downloads the newest file first and uploads what NEFORUM wrote
/// (lib/platform/files_app_folder.dart).
class SyncFolderPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  private var pendingPick: FlutterResult?

  static func register(in registry: FlutterPluginRegistry) {
    if let registrar = registry.registrar(forPlugin: "NeforumSyncFolder") {
      register(with: registrar)
    }
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "neforum/syncfolder", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(SyncFolderPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "pick" {
      pick(result)
      return
    }
    let args = call.arguments as? [String: Any] ?? [:]
    guard let encoded = args["bookmark"] as? String, let bookmark = Data(base64Encoded: encoded) else {
      result(FlutterError(code: "bookmark", message: "No folder was chosen.", details: nil))
      return
    }
    DispatchQueue.global(qos: .utility).async {
      let out: Any?
      do {
        out = try SyncFolderPlugin.run(call.method, bookmark: bookmark, args: args)
      } catch let error as SyncFolderError {
        out = FlutterError(code: error.code, message: error.message, details: nil)
      } catch {
        out = FlutterError(code: "io", message: error.localizedDescription, details: nil)
      }
      DispatchQueue.main.async { result(out) }
    }
  }

  // MARK: Picking the folder

  private func pick(_ result: @escaping FlutterResult) {
    guard pendingPick == nil, let top = SyncFolderPlugin.topController() else {
      result(nil)
      return
    }
    pendingPick = result
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    top.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pendingPick else { return }
    pendingPick = nil
    guard let url = urls.first else {
      result(nil)
      return
    }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
      result(["bookmark": bookmark.base64EncodedString(), "name": url.lastPathComponent, "path": url.path])
    } catch {
      result(FlutterError(code: "bookmark", message: "iOS did not allow NEFORUM to keep this folder: \(error.localizedDescription)", details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pendingPick?(nil)
    pendingPick = nil
  }

  private static func topController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = scenes.flatMap { $0.windows }
    var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  // MARK: Reading and writing in the folder

  private static func run(_ method: String, bookmark: Data, args: [String: Any]) throws -> Any? {
    var stale = false
    let folder = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    let scoped = folder.startAccessingSecurityScopedResource()
    defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
    let name = args["name"] as? String ?? ""
    let file = folder.appendingPathComponent(name)
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var out: Any?
    var failure: Error?

    switch method {
    case "read":
      coordinator.coordinate(readingItemAt: file, options: [], error: &coordinationError) { url in
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
          let data = try Data(contentsOf: url)
          out = ["bytes": FlutterStandardTypedData(bytes: data), "version": version(of: url) ?? ""] as [String: Any]
        } catch {
          failure = error
        }
      }
    case "write":
      guard let typed = args["bytes"] as? FlutterStandardTypedData else {
        throw SyncFolderError(code: "args", message: "Nothing to write.")
      }
      let force = args["force"] as? Bool ?? false
      let ifMatch = args["ifMatch"] as? String
      coordinator.coordinate(
        readingItemAt: file, options: [], writingItemAt: file, options: .forReplacing, error: &coordinationError
      ) { readURL, writeURL in
        let current: String? = FileManager.default.fileExists(atPath: readURL.path) ? (version(of: readURL) ?? "") : nil
        if !force && current != ifMatch {
          failure = SyncFolderError(code: "conflict", message: "The sync file changed while NEFORUM was writing it.")
          return
        }
        do {
          try typed.data.write(to: writeURL, options: .atomic)
          out = version(of: writeURL) ?? ""
        } catch {
          failure = error
        }
      }
    case "list":
      coordinator.coordinate(readingItemAt: folder, options: [.immediatelyAvailableMetadataOnly], error: &coordinationError) { url in
        do {
          // Files iCloud has not downloaded yet show up as ".name.icloud".
          out = try FileManager.default.contentsOfDirectory(atPath: url.path).map { entry -> String in
            if entry.hasPrefix(".") && entry.hasSuffix(".icloud") {
              return String(entry.dropFirst().dropLast(".icloud".count))
            }
            return entry
          }
        } catch {
          failure = error
        }
      }
    case "delete":
      coordinator.coordinate(writingItemAt: file, options: .forDeleting, error: &coordinationError) { url in
        do {
          if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } catch {
          failure = error
        }
      }
    default:
      return FlutterMethodNotImplemented
    }
    if let error = coordinationError { throw error }
    if let error = failure { throw error }
    return out
  }

  /// Changes whenever the file does: modification time (microseconds) and size.
  private static func version(of url: URL) -> String? {
    guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
          let modified = values.contentModificationDate else { return nil }
    return "\(Int64(modified.timeIntervalSince1970 * 1_000_000)):\(values.fileSize ?? 0)"
  }
}
