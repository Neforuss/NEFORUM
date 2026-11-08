import ActivityKit
import BackgroundTasks
import Flutter
import UIKit

/// Own Live Activity next to iOS 26's continued task. Both may show on iOS 26 and
/// later: only ours can say "Paused by iOS". Set this to false if a device test says
/// the pair looks wrong.
let kOwnActivityBesideContinuedTask = true

/// How long the extension's bundle is called. A re-signing tool can strip it.
private let kLiveActivityExtension = "NeforumLiveActivity.appex"

/// Live Activity: at most one plain refresh in this time, besides stage changes.
private let kLiveActivityMinInterval: TimeInterval = 30

/// Set on every update: if the app stops updating, iOS flips the activity to its
/// paused words at this distance, with nothing of NEFORUM's running.
private let kLiveActivityStaleSeconds: TimeInterval = 45

/// A final state stays on the Lock Screen for this long.
private let kLiveActivityEndedSeconds: TimeInterval = 30 * 60

/// How long a continued task gets to start before the run relies on the assertion.
private let kContinuedTaskWatchdogSeconds: TimeInterval = 2

/// iOS's own bar on a continued task. See `systemUnits` in publish_run_surface.dart.
private let kSystemProgressUnits: Int64 = 1_000_000

/// "neforum/publish_host" on iOS (lib/platform/publish_host.dart). Registered in every
/// engine, so the isolate behind a notification action can end its assertion too.
class PublishRunPlugin: NSObject, FlutterPlugin {
  private var channel: FlutterMethodChannel?

  static func register(in registry: FlutterPluginRegistry) {
    if let registrar = registry.registrar(forPlugin: "NeforumPublishRun") {
      register(with: registrar)
    }
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "neforum/publish_host", binaryMessenger: registrar.messenger())
    let instance = PublishRunPlugin()
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let keeper = PublishRunKeeper.shared
    switch call.method {
    case "begin":
      guard let postId = args["postId"] as? String else {
        result(false)
        return
      }
      keeper.listener = channel
      result(keeper.begin(postId: postId, title: args["title"] as? String ?? ""))
    case "update":
      keeper.update(args)
      result(nil)
    case "end":
      guard let postId = args["postId"] as? String else {
        result(nil)
        return
      }
      keeper.end(postId: postId, summary: args["summary"] as? String ?? "")
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// Keeps a post going when NEFORUM leaves the screen, and says what is true while it
/// does. What iOS allows:
///
/// * a background assertion: about 30 seconds, on every version, taken at the tap;
/// * on iOS 26 and later a continued task as well: minutes, best effort;
/// * a Live Activity on iOS 16.2 and later, which goes stale by itself when the app
///   stops updating it.
///
/// A suspended app runs no code, so none of this runs while iOS has the app paused.
/// The run never waits on any of it.
final class PublishRunKeeper {
  static let shared = PublishRunKeeper()

  weak var listener: FlutterMethodChannel?

  private struct Run {
    var title: String
    /// `Activity<PublishActivityAttributes>`, typed only where iOS has it.
    var activity: AnyObject?
    var lastKey = ""
    var lastAppliedAt = Date.distantPast
    var lastBackgrounded = false
    var lastUnits: Int64 = 0
    var activityFailed = false
  }

  private var runs: [String: Run] = [:]
  private var assertion: UIBackgroundTaskIdentifier = .invalid
  private var actionAssertion: UIBackgroundTaskIdentifier = .invalid

  /// A continued task that has started, and the one still waiting for its handler.
  private var continuedTask: AnyObject?
  private var pendingContinuedIdentifier: String?

  private init() {}

  // MARK: Contract

  /// Dart calls this again for a run it already began: at the tap with the run's
  /// real title after a first "Getting your post ready", when the plan brings the
  /// networks, and on the person's Continue. Each takes the assertion again if it
  /// lapsed, and a new title reaches iOS's own view of the only run.
  func begin(postId: String, title: String) -> Bool {
    var run = runs[postId] ?? Run(title: title)
    let retitled = !title.isEmpty && run.title != title
    if !title.isEmpty { run.title = title }
    runs[postId] = run
    takeAssertion()
    if continuedTask == nil && pendingContinuedIdentifier == nil {
      startContinuedTask(title: run.title)
    } else if retitled && runs.count == 1 {
      retitleContinuedTask(run.title)
    }
    return assertion != .invalid
  }

  func update(_ snapshot: [String: Any]) {
    guard let postId = snapshot["postId"] as? String, var run = runs[postId] else { return }
    // Back in front after iOS let the assertion lapse: time for the next time away.
    if assertion == .invalid && UIApplication.shared.applicationState != .background { takeAssertion() }
    updateContinuedTask(snapshot)
    if #available(iOS 16.2, *) {
      applyActivity(&run, postId: postId, snapshot: snapshot)
    }
    runs[postId] = run
  }

  func end(postId: String, summary: String) {
    releaseActionAssertion()
    guard let run = runs.removeValue(forKey: postId) else { return }
    if #available(iOS 16.2, *) { finishActivity(run, summary: summary) }
    if runs.isEmpty {
      finishContinuedTask(success: true)
      releaseAssertion()
    }
  }

  // MARK: Notification action

  /// "Publish now" on a text post's reminder. The notification plugin calls its
  /// completion handler right after queuing the event, before Dart has started,
  /// and iOS may suspend the app from then on. This comes before that.
  func beginNotificationAction() {
    guard actionAssertion == .invalid else { return }
    actionAssertion = UIApplication.shared.beginBackgroundTask(withName: "NEFORUM Publish now") { [weak self] in
      self?.releaseActionAssertion()
    }
  }

  private func releaseActionAssertion() {
    guard actionAssertion != .invalid else { return }
    UIApplication.shared.endBackgroundTask(actionAssertion)
    actionAssertion = .invalid
  }

  // MARK: Background assertion

  private func takeAssertion() {
    guard assertion == .invalid else { return }
    assertion = UIApplication.shared.beginBackgroundTask(withName: "NEFORUM posting") { [weak self] in
      self?.assertionExpired()
    }
  }

  /// About a second to get out, or the system kills the app.
  private func assertionExpired() {
    if continuedTask == nil { send("windowClosing") }
    releaseAssertion()
  }

  private func releaseAssertion() {
    guard assertion != .invalid else { return }
    UIApplication.shared.endBackgroundTask(assertion)
    assertion = .invalid
  }

  private func send(_ method: String) {
    listener?.invokeMethod(method, arguments: nil)
  }

  // MARK: Continued task (iOS 26 and later)

  private func startContinuedTask(title: String) {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) { submitContinuedTask(title: title) }
    #endif
  }

  private func retitleContinuedTask(_ title: String) {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
      task.updateTitle(title, subtitle: task.subtitle)
    }
    #endif
  }

  private func updateContinuedTask(_ snapshot: [String: Any]) {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) { reportContinuedTask(snapshot) }
    #endif
  }

  private func finishContinuedTask(success: Bool) {
    pendingContinuedIdentifier = nil
    #if compiler(>=6.2)
    if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
      task.setTaskCompleted(success: success)
    }
    #endif
    continuedTask = nil
  }

  #if compiler(>=6.2)
  /// The identifier is made here from the bundle's real id, since re-signing tools
  /// rename the bundle, and unique per run, since registering one twice in a session
  /// can crash. A refused or silent request only costs the longer time.
  @available(iOS 26.0, *)
  private func submitContinuedTask(title: String) {
    guard let bundle = Bundle.main.bundleIdentifier else { return }
    let identifier = "\(bundle).publish.\(UUID().uuidString.lowercased())"
    let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
      guard let self = self, let continued = task as? BGContinuedProcessingTask, self.pendingContinuedIdentifier == identifier else {
        // Later than the watchdog: the run already relies on the assertion.
        task.setTaskCompleted(success: false)
        return
      }
      self.pendingContinuedIdentifier = nil
      self.continuedTask = continued
      continued.progress.totalUnitCount = kSystemProgressUnits
      continued.expirationHandler = { [weak self] in
        DispatchQueue.main.async { self?.continuedTaskExpired() }
      }
    }
    guard registered else { return }
    let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: title)
    request.strategy = .fail
    do {
      pendingContinuedIdentifier = identifier
      try BGTaskScheduler.shared.submit(request)
    } catch {
      pendingContinuedIdentifier = nil
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + kContinuedTaskWatchdogSeconds) { [weak self] in
      if self?.pendingContinuedIdentifier == identifier { self?.pendingContinuedIdentifier = nil }
    }
  }

  /// iOS's expiry and a person's Stop arrive here alike, so Dart asks instead of
  /// guessing.
  @available(iOS 26.0, *)
  private func continuedTaskExpired() {
    finishContinuedTask(success: false)
    send("timedOut")
  }

  /// D6: real units only. The bar never falls, though a new wait starts its polls over.
  @available(iOS 26.0, *)
  private func reportContinuedTask(_ snapshot: [String: Any]) {
    guard let task = continuedTask as? BGContinuedProcessingTask else { return }
    if let units = (snapshot["systemUnits"] as? NSNumber)?.int64Value {
      task.progress.completedUnitCount = max(task.progress.completedUnitCount, min(units, kSystemProgressUnits))
    }
    if let subtitle = snapshot["systemSubtitle"] as? String {
      task.updateTitle(task.title, subtitle: subtitle)
    }
  }
  #endif

  // MARK: Live Activity

  /// Whether a Live Activity can show at all: iOS allows it, the person did not turn
  /// it off, and a re-signing tool did not strip the extension.
  @available(iOS 16.2, *)
  private func activityIsPossible() -> Bool {
    if !kOwnActivityBesideContinuedTask && continuedTask != nil { return false }
    guard let plugIns = Bundle.main.builtInPlugInsURL,
          FileManager.default.fileExists(atPath: plugIns.appendingPathComponent(kLiveActivityExtension).path) else { return false }
    return ActivityAuthorizationInfo().areActivitiesEnabled
  }

  /// Stage or outcome changes go out at once; otherwise at most every 30 s, and each
  /// sets a new stale date, so it stays fresh only while this process runs.
  @available(iOS 16.2, *)
  private func applyActivity(_ run: inout Run, postId: String, snapshot: [String: Any]) {
    guard let label = snapshot["activityLabel"] as? String else {
      // The reducer says nothing should show: getting ready, or stopped.
      if let activity = run.activity as? Activity<PublishActivityAttributes> {
        run.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
      }
      return
    }
    let state = PublishActivityAttributes.ContentState(
      phase: snapshot["phase"] as? String ?? "",
      label: label,
      shortLabel: snapshot["activityShortLabel"] as? String ?? "",
      pausedLabel: snapshot["pausedLabel"] as? String ?? label,
      pausedShortLabel: snapshot["pausedShortLabel"] as? String ?? "",
      stageLabel: snapshot["stageLabel"] as? String,
      network: snapshot["currentNetwork"] as? String,
      permille: (snapshot["postPermille"] as? NSNumber)?.intValue,
      updatedAt: Date()
    )
    let backgrounded = snapshot["backgrounded"] as? Bool ?? false
    let key = [state.phase, state.label, state.stageLabel ?? "", state.network ?? ""].joined(separator: "|")
    let now = Date()
    let due = key != run.lastKey || backgrounded != run.lastBackgrounded || now.timeIntervalSince(run.lastAppliedAt) >= kLiveActivityMinInterval
    guard due else { return }
    run.lastKey = key
    run.lastBackgrounded = backgrounded
    run.lastAppliedAt = now
    let content = ActivityContent(state: state, staleDate: now.addingTimeInterval(kLiveActivityStaleSeconds))
    if let activity = run.activity as? Activity<PublishActivityAttributes> {
      Task { await activity.update(content) }
      return
    }
    guard !run.activityFailed, activityIsPossible() else { return }
    do {
      // No push: self-signed builds cannot have it, and nothing here needs a server.
      run.activity = try Activity<PublishActivityAttributes>.request(attributes: PublishActivityAttributes(postId: postId), content: content, pushType: nil)
    } catch {
      // Not in front, too many activities, or turned off: no surface, and the run goes on.
      run.activityFailed = true
    }
  }

  @available(iOS 16.2, *)
  private func finishActivity(_ run: Run, summary: String) {
    guard let activity = run.activity as? Activity<PublishActivityAttributes> else { return }
    let state = PublishActivityAttributes.ContentState(
      phase: "done",
      label: summary,
      shortLabel: "",
      pausedLabel: summary,
      pausedShortLabel: "",
      stageLabel: nil,
      network: nil,
      permille: nil,
      updatedAt: Date()
    )
    let content = ActivityContent(state: state, staleDate: nil)
    Task { await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(kLiveActivityEndedSeconds))) }
  }

  /// An activity can outlive the process that started it. Nothing is running at a new
  /// launch, so what it still says is out of date.
  func endLeftoverActivities() {
    guard #available(iOS 16.2, *), runs.isEmpty else { return }
    for activity in Activity<PublishActivityAttributes>.activities {
      Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
  }
}
