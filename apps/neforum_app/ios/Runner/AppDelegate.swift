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

/// "neforum/syncfolder": the sync file in a location the user picked in the
/// Files app (lib/platform/files_app_folder.dart):
///
/// * a folder (iCloud Drive, Dropbox, On My iPhone...), or
/// * the sync file itself, for apps that do not let other apps pick their
///   folders and show up grayed out in the folder picker (Google Drive,
///   OneDrive, MEGA...) but do let them open and save one file in place.
///   "create" saves a new, empty sync file into such an app.
///
/// Access survives restarts through a bookmark, and every read and write
/// goes through NSFileCoordinator, so iCloud or the cloud app downloads the
/// newest file first and uploads what NEFORUM wrote. An empty file counts as
/// no sync file yet.
///
/// Tapping a `.neforumsync` file in the Files app (or "Open in NEFORUM")
/// opens it in place too (Info.plist declares the type, org.neforum.sync):
/// the app takes it with "takeOpened" and offers to sync with it.
class SyncFolderPlugin: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate, UIDocumentPickerDelegate {
  private var pendingPick: FlutterResult?
  private var pendingIsFile = false
  private var channel: FlutterMethodChannel?

  /// A sync file opened from the Files app, until the app takes it.
  private static var openedFile: [String: Any]?

  /// NEFORUM's own file type (declared in Info.plist), so the picker and the
  /// Files app know a .neforumsync file instead of graying it out.
  static let syncFileType = UTType(exportedAs: "org.neforum.sync", conformingTo: .data)

  static func register(in registry: FlutterPluginRegistry) {
    if let registrar = registry.registrar(forPlugin: "NeforumSyncFolder") {
      register(with: registrar)
    }
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "neforum/syncfolder", binaryMessenger: registrar.messenger())
    let instance = SyncFolderPlugin()
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addSceneDelegate(instance)
  }

  // MARK: Sync files opened from the Files app

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions?) -> Bool {
    guard let contexts = connectionOptions?.urlContexts else { return false }
    return receive(contexts)
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    return receive(URLContexts)
  }

  /// Keeps a bookmark of an opened .neforumsync file; other links (sign-in
  /// redirects) are left to the rest of the app.
  private func receive(_ contexts: Set<UIOpenURLContext>) -> Bool {
    guard let context = contexts.first(where: { $0.url.isFileURL && $0.url.pathExtension.lowercased() == "neforumsync" }) else {
      return false
    }
    let url = context.url
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    var info: [String: Any] = ["name": url.lastPathComponent, "inPlace": context.options.openInPlace]
    if context.options.openInPlace,
       let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
      info["bookmark"] = bookmark.base64EncodedString()
    }
    SyncFolderPlugin.openedFile = info
    channel?.invokeMethod("openedAvailable", arguments: nil)
    return true
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "takeOpened" {
      result(SyncFolderPlugin.openedFile)
      SyncFolderPlugin.openedFile = nil
      return
    }
    if call.method == "pick" {
      pick(args["mode"] as? String ?? "folder", result)
      return
    }
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

  // MARK: Picking

  private func pick(_ mode: String, _ result: @escaping FlutterResult) {
    guard pendingPick == nil, let top = SyncFolderPlugin.topController() else {
      result(nil)
      return
    }
    let picker: UIDocumentPickerViewController
    switch mode {
    case "file":
      // NEFORUM's own type first, then anything: cloud apps report a file
      // type of their own choosing for an extension iOS did not know.
      picker = UIDocumentPickerViewController(
        forOpeningContentTypes: [SyncFolderPlugin.syncFileType, .data, .item], asCopy: false)
    case "create":
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("NEFORUM.neforumsync")
      try? FileManager.default.removeItem(at: url)
      guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
        result(FlutterError(code: "io", message: "Could not prepare the sync file.", details: nil))
        return
      }
      picker = UIDocumentPickerViewController(forExporting: [url], asCopy: false)
    default:
      picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
    }
    pendingPick = result
    pendingIsFile = mode != "folder"
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
    if pendingIsFile && url.hasDirectoryPath {
      result(FlutterError(code: "picker", message: "That is a folder: use Choose folder for folders, or open the folder and tap NEFORUM.neforumsync.", details: nil))
      return
    }
    do {
      let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
      result([
        "bookmark": bookmark.base64EncodedString(), "name": url.lastPathComponent, "path": url.path, "file": pendingIsFile,
      ] as [String: Any])
    } catch {
      result(FlutterError(code: "bookmark", message: "iOS did not allow NEFORUM to keep this location: \(error.localizedDescription)", details: nil))
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

  // MARK: Reading and writing

  private static func run(_ method: String, bookmark: Data, args: [String: Any]) throws -> Any? {
    var stale = false
    let base = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    let scoped = base.startAccessingSecurityScopedResource()
    defer { if scoped { base.stopAccessingSecurityScopedResource() } }
    // The bookmark is the sync file itself, or the folder it lives in.
    let isFile = args["file"] as? Bool ?? false
    let file = isFile ? base : base.appendingPathComponent(args["name"] as? String ?? "")
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var out: Any?
    var failure: Error?

    switch method {
    case "read":
      coordinator.coordinate(readingItemAt: file, options: [], error: &coordinationError) { url in
        guard let current = version(of: url) else { return }
        do {
          let data = try Data(contentsOf: url)
          out = ["bytes": FlutterStandardTypedData(bytes: data), "version": current] as [String: Any]
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
        if !force && version(of: readURL) != ifMatch {
          failure = SyncFolderError(code: "conflict", message: "The sync file changed while NEFORUM was writing it.")
          return
        }
        do {
          // A picked file can only be written in place: there is no access
          // to its folder for the temporary file of an atomic write.
          try typed.data.write(to: writeURL, options: isFile ? Data.WritingOptions() : .atomic)
          out = version(of: writeURL) ?? ""
        } catch {
          failure = error
        }
      }
    case "list":
      if isFile { return [String]() }
      coordinator.coordinate(readingItemAt: base, options: [.immediatelyAvailableMetadataOnly], error: &coordinationError) { url in
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
      if isFile { return nil }
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

  /// Changes whenever the file does: modification time (microseconds) and
  /// size. `nil` when there is no file, or only an empty one.
  private static func version(of url: URL) -> String? {
    guard FileManager.default.fileExists(atPath: url.path),
          let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
          let size = values.fileSize, size > 0 else { return nil }
    let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
    return "\(Int64(modified * 1_000_000)):\(size)"
  }
}
