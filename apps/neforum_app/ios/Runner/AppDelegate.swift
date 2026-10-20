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

/// A failure with a code the Dart side understands ("conflict", "bookmark").
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
/// no sync file yet. "probe" tells whether NEFORUM may change the location
/// without changing anything.
///
/// Tapping a `.neforumsync` file in the Files app (or "Open in NEFORUM")
/// opens it in place too (Info.plist declares the type, org.neforum.sync):
/// the app takes it with "takeOpened" and offers to sync with it.
class SyncFolderPlugin: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate, UIDocumentPickerDelegate {
  private var pendingPick: FlutterResult?
  private var pendingMode = "folder"
  /// The picker that answers [pendingPick], to tell when it went away
  /// without calling back.
  private weak var activePicker: UIDocumentPickerViewController?
  private var channel: FlutterMethodChannel?

  /// A sync file opened from the Files app, until the app takes it.
  private static var openedFile: [String: Any]?

  /// The sync file's name (kSyncFileName in neforum_core).
  static let syncFileName = "NEFORUM.neforumsync"

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
    if let earlier = pendingPick {
      // A picker still on screen answers the earlier call. One that never
      // showed, or went away without calling back, must not block every
      // later Choose... press.
      if let picker = activePicker, picker.presentingViewController != nil {
        result(nil)
        return
      }
      pendingPick = nil
      activePicker = nil
      earlier(nil)
    }
    guard let top = SyncFolderPlugin.topController() else {
      result(FlutterError(code: "picker", message: "NEFORUM could not show the file picker: open NEFORUM and try again.", details: nil))
      return
    }
    let picker: UIDocumentPickerViewController
    switch mode {
    case "file":
      // NEFORUM's own type first, then any file: cloud apps report a file
      // type of their own choosing for an extension iOS did not know. Not
      // .item, which made folders pickable here.
      picker = UIDocumentPickerViewController(
        forOpeningContentTypes: [SyncFolderPlugin.syncFileType, .data], asCopy: false)
    case "create":
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(SyncFolderPlugin.syncFileName)
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
    pendingMode = mode
    activePicker = picker
    picker.delegate = self
    picker.allowsMultipleSelection = false
    picker.shouldShowFileExtensions = true
    // Only Cancel or a choice closes it, so the delegate always hears back.
    picker.isModalInPresentation = true
    top.present(picker, animated: true) { [weak self] in
      // iOS did not show it (another sheet was in the way...).
      guard let self = self, self.activePicker === picker, picker.presentingViewController == nil else { return }
      self.finishPick(FlutterError(code: "picker", message: "iOS did not show the file picker: try again.", details: nil))
    }
  }

  /// Answers the pending pick, once.
  private func finishPick(_ value: Any?) {
    guard let result = pendingPick else { return }
    pendingPick = nil
    activePicker = nil
    result(value)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard controller === activePicker else { return }
    let mode = pendingMode
    let isFile = mode != "folder"
    guard let url = urls.first else {
      finishPick(nil)
      return
    }
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    if isFile && url.hasDirectoryPath {
      finishPick(FlutterError(code: "picker", message: "That is a folder: use Choose folder for folders, or open the folder and tap NEFORUM.neforumsync.", details: nil))
      return
    }
    if mode == "create" && url.lastPathComponent != SyncFolderPlugin.syncFileName {
      // "Keep Both" next to an existing sync file, or the cloud app renamed
      // it: the other devices would never find that copy.
      DispatchQueue.global(qos: .utility).async { SyncFolderPlugin.removeIfEmpty(url) }
      finishPick(FlutterError(
        code: "picker",
        message: "The file was saved as \"\(url.lastPathComponent)\", so your other devices would not find it. If NEFORUM.neforumsync is already there, use Choose the sync file. Otherwise create it again with that exact name.",
        details: nil))
      return
    }
    do {
      let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
      finishPick([
        "bookmark": bookmark.base64EncodedString(), "name": url.lastPathComponent, "path": url.path, "file": isFile,
      ] as [String: Any])
    } catch {
      finishPick(FlutterError(code: "bookmark", message: "iOS did not allow NEFORUM to keep this location: \(error.localizedDescription)", details: nil))
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    guard controller === activePicker else { return }
    finishPick(nil)
  }

  /// Removes the file "create" saved under another name, only if it is
  /// still empty: a file with something in it is never touched.
  private static func removeIfEmpty(_ url: URL) {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    var coordinationError: NSError?
    NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { target in
      guard size(of: target) == 0 else { return }
      try? FileManager.default.removeItem(at: target)
    }
  }

  /// The top view controller in NEFORUM's window in the foreground, to show
  /// the picker on; `nil` when there is none.
  private static func topController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .filter { $0.session.role == .windowApplication }
    guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
      ?? scenes.first(where: { $0.activationState == .foregroundInactive }) else { return nil }
    var top = (scene.keyWindow ?? scene.windows.first)?.rootViewController
    while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
    return top
  }

  // MARK: Reading and writing

  private static func run(_ method: String, bookmark: Data, args: [String: Any]) throws -> Any? {
    // A stale bookmark still resolves to the right item (it was moved or
    // renamed), so it is used as it is; only a refused access is an error.
    var stale = false
    let base = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    let scoped = base.startAccessingSecurityScopedResource()
    defer { if scoped { base.stopAccessingSecurityScopedResource() } }
    // iOS withdrew the access. A location inside NEFORUM's own container
    // needs no granted access (and its path changes when the app is updated).
    if !scoped && !isInsideContainer(base) {
      throw SyncFolderError(code: "bookmark", message: "iOS no longer lets NEFORUM use this location: choose it again in Settings > Sync.")
    }
    // The bookmark is the sync file itself, or the folder it lives in.
    let isFile = args["file"] as? Bool ?? false
    let file = isFile ? base : base.appendingPathComponent(args["name"] as? String ?? "")
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var out: Any?
    var failure: Error?

    switch method {
    case "probe":
      // Whether NEFORUM may change the sync file, or add files to the
      // folder, asked without changing anything. The file is fetched first;
      // the folder only needs what iOS already knows.
      let options: NSFileCoordinator.ReadingOptions = isFile ? [] : .immediatelyAvailableMetadataOnly
      coordinator.coordinate(readingItemAt: base, options: options, error: &coordinationError) { url in
        guard FileManager.default.fileExists(atPath: url.path) else {
          let what = isFile ? "The sync file" : "The folder"
          failure = SyncFolderError(code: "bookmark", message: "\(what) is gone: choose it again in Settings > Sync.")
          return
        }
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let writable = (try? fresh.resourceValues(forKeys: [.isWritableKey]))?.isWritable ?? true
        out = writable && FileManager.default.isWritableFile(atPath: url.path)
      }
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
          if isFile && size(of: writeURL) != Int64(typed.data.count) {
            throw SyncFolderError(code: "io", message: "The cloud app did not replace the whole file.")
          }
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
  /// size, from the file system rather than cached URL values. `nil` when
  /// there is no file, or only an empty one.
  private static func version(of url: URL) -> String? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0 else { return nil }
    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return "\(Int64(modified * 1_000_000)):\(size)"
  }

  /// The file's size in bytes from the file system; `nil` when it is not
  /// there.
  private static func size(of url: URL) -> Int64? {
    return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
  }

  /// Whether [url] is in NEFORUM's own container ("On My iPhone > NEFORUM"),
  /// where iOS grants no security-scoped access because none is needed.
  private static func isInsideContainer(_ url: URL) -> Bool {
    let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
    let path = url.resolvingSymlinksInPath().path
    return path == home || path.hasPrefix(home + "/")
  }
}
