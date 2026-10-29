import AVFoundation
import CoreImage
import ImageIO

#if os(iOS)
import Flutter
import UIKit
#else
import FlutterMacOS
#endif

/// "neforum/video": the video caption compositor
/// (lib/platform/video_compositor.dart). The iOS and macOS runners share this
/// file (the macOS project compiles it from ios/Runner).
///
/// AVAssetExportSession re-encodes the video as H.264 and AAC in an MP4 of the
/// requested frame. [CaptionCompositor] draws every frame with Core Image:
/// the background colour, the picture turned upright (the track's preferred
/// transform) and stretched into the video rectangle the Dart side computed,
/// and the caption PNG over the whole frame.
///
/// Frames for previews come from AVAssetImageGenerator. Re-encoding at a set
/// bitrate (transcode, audioVideo, transcodeAudio) needs AVAssetReader and
/// AVAssetWriter, because AVAssetExportSession cannot set one: see
/// [MediaWriterJob].
final class VideoCompositorPlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  /// The export in progress (Dart sends one at a time); main thread only.
  private var session: AVAssetExportSession?
  /// The reader-writer job in progress; main thread only.
  private var job: MediaWriterJob?
  private var progressTimer: Timer?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  #if os(iOS)
  static func register(in registry: FlutterPluginRegistry) {
    if let registrar = registry.registrar(forPlugin: "NeforumVideoCompositor") {
      register(with: registrar)
    }
  }
  #endif

  static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(name: "neforum/video", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(VideoCompositorPlugin(channel: channel), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "isSupported":
      // AVFoundation always has H.264 and AAC encoders on these systems.
      result(true)
    case "probe":
      guard let path = args["path"] as? String, !path.isEmpty else {
        result(FlutterError(code: "args", message: "No video was given.", details: nil))
        return
      }
      Task {
        let probe = await VideoCompositorPlugin.probe(path)
        DispatchQueue.main.async {
          if let probe = probe {
            result(probe)
          } else {
            result(FlutterError(code: "probe", message: "NEFORUM could not read this video.", details: nil))
          }
        }
      }
    case "compose":
      compose(args, result)
    case "frame":
      frame(args, result)
    case "transcode":
      transcode(args, result)
    case "audioVideo":
      audioVideo(args, result)
    case "audioFormats":
      // AVFoundation always has an AAC encoder; neither system ships an MP3 one.
      result(["m4a"])
    case "transcodeAudio":
      transcodeAudio(args, result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Probing

  /// Stored size, clockwise rotation, duration and sound; nil when the file
  /// has no readable video.
  static func probe(_ path: String) async -> [String: Any]? {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    do {
      guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
      let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
      let duration = try await asset.load(.duration)
      let audio = try await asset.loadTracks(withMediaType: .audio)
      guard size.width > 0, size.height > 0 else { return nil }
      return [
        "width": Int(size.width.rounded()),
        "height": Int(size.height.rounded()),
        "rotation": rotation(of: transform),
        "durationMs": duration.isNumeric ? Int((duration.seconds * 1000).rounded()) : 0,
        "hasAudio": !audio.isEmpty,
      ]
    } catch {
      return nil
    }
  }

  /// The clockwise quarter turn (0, 90, 180, 270) a preferred transform
  /// gives the picture: phones store portrait video as a landscape frame
  /// turned 90.
  static func rotation(of transform: CGAffineTransform) -> Int {
    let degrees = atan2(Double(transform.b), Double(transform.a)) * 180 / Double.pi
    let quarters = Int((degrees / 90).rounded())
    return ((quarters % 4) + 4) % 4 * 90
  }

  // MARK: Composing

  private func compose(_ args: [String: Any], _ result: @escaping FlutterResult) {
    func int(_ key: String) -> Int { (args[key] as? NSNumber)?.intValue ?? 0 }
    let input = args["inputPath"] as? String ?? ""
    let output = args["outputPath"] as? String ?? ""
    let png = (args["overlayPng"] as? FlutterStandardTypedData)?.data
    let width = int("frameWidth")
    let height = int("frameHeight")
    let video = CGRect(x: int("videoLeft"), y: int("videoTop"), width: int("videoWidth"), height: int("videoHeight"))
    let rgb = int("backgroundRgb")
    let id = int("id")
    let frameOk = (16...4096).contains(width) && (16...4096).contains(height) && width % 2 == 0 && height % 2 == 0
    let videoOk = video.width > 0 && video.height > 0 && video.minX >= 0 && video.minY >= 0
      && video.maxX <= CGFloat(width) && video.maxY <= CGFloat(height)
    guard frameOk, videoOk, !input.isEmpty, !output.isEmpty, input != output else {
      result(FlutterError(code: "args", message: "The video request is not complete.", details: nil))
      return
    }
    guard session == nil, job == nil else {
      result(FlutterError(code: "busy", message: "Another video is being made.", details: nil))
      return
    }
    guard let data = png, let overlay = VideoCompositorPlugin.image(from: data) else {
      result(FlutterError(code: "compose", message: "The caption image could not be read.", details: nil))
      return
    }
    let background = CIColor(
      red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
      blue: CGFloat(rgb & 0xFF) / 255)
    let outputURL = URL(fileURLWithPath: output)
    Task {
      do {
        let session = try await VideoCompositorPlugin.exportSession(
          input: URL(fileURLWithPath: input), output: outputURL, overlay: overlay,
          frame: CGSize(width: width, height: height), video: video, background: background)
        DispatchQueue.main.async { self.run(session, id: id, output: outputURL, result: result) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "compose", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private static func image(from png: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  private static func exportSession(
    input: URL, output: URL, overlay: CGImage, frame: CGSize, video: CGRect, background: CIColor
  ) async throws -> AVAssetExportSession {
    let asset = AVURLAsset(url: input)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw CompositionError("This file has no video.")
    }
    let (transform, frameRate) = try await track.load(.preferredTransform, .nominalFrameRate)
    let duration = try await asset.load(.duration)
    guard duration.isNumeric, duration > .zero else { throw CompositionError("This video has no length.") }

    let composition = AVMutableVideoComposition()
    composition.customVideoCompositorClass = CaptionCompositor.self
    composition.renderSize = frame
    let rate = frameRate > 0 && frameRate <= 120 ? Double(frameRate) : 30
    composition.frameDuration = CMTime(value: CMTimeValue((600 / rate).rounded()), timescale: 600)
    // Standard dynamic range in BT.709, whatever the source (HDR included).
    composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
    composition.instructions = [
      CaptionInstruction(
        timeRange: CMTimeRange(start: .zero, duration: duration), trackID: track.trackID,
        orientation: orientation(of: rotation(of: transform)), frame: frame, video: video,
        background: background, overlay: overlay)
    ]

    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
      throw CompositionError("This video cannot be exported on this device.")
    }
    session.outputURL = output
    session.outputFileType = .mp4
    session.shouldOptimizeForNetworkUse = true
    session.videoComposition = composition
    return session
  }

  /// The Core Image orientation that shows a picture turned [rotation]
  /// degrees clockwise upright.
  private static func orientation(of rotation: Int) -> CGImagePropertyOrientation {
    switch rotation {
    case 90: return .right
    case 180: return .down
    case 270: return .left
    default: return .up
    }
  }

  private func run(_ session: AVAssetExportSession, id: Int, output: URL, result: @escaping FlutterResult) {
    guard self.session == nil, job == nil else {
      result(FlutterError(code: "busy", message: "Another video is being made.", details: nil))
      return
    }
    self.session = session
    try? FileManager.default.removeItem(at: output)
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      guard let self = self, let session = self.session else { return }
      self.channel.invokeMethod("progress", arguments: ["id": id, "progress": Double(session.progress)])
    }
    RunLoop.main.add(timer, forMode: .common)
    progressTimer = timer
    #if os(iOS)
    // A short trip to another app should not stop the export; when iOS ends
    // the extra time, the export is cancelled (both run on the main thread).
    var backgroundTask = UIBackgroundTaskIdentifier.invalid
    func endBackgroundTask() {
      guard backgroundTask != .invalid else { return }
      UIApplication.shared.endBackgroundTask(backgroundTask)
      backgroundTask = .invalid
    }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "NEFORUM video") {
      session.cancelExport()
      endBackgroundTask()
    }
    #endif
    session.exportAsynchronously { [weak self] in
      DispatchQueue.main.async {
        self?.progressTimer?.invalidate()
        self?.progressTimer = nil
        self?.session = nil
        #if os(iOS)
        endBackgroundTask()
        #endif
        if session.status == .completed {
          result(nil)
          return
        }
        try? FileManager.default.removeItem(at: output)
        let cancelled = session.status == .cancelled
        result(FlutterError(
          code: cancelled ? "cancelled" : "compose",
          message: session.error?.localizedDescription ?? "The video could not be made.", details: nil))
      }
    }
  }

  // MARK: Frames

  private func frame(_ args: [String: Any], _ result: @escaping FlutterResult) {
    guard let path = args["path"] as? String, !path.isEmpty else {
      result(FlutterError(code: "args", message: "No video was given.", details: nil))
      return
    }
    let position = max(0, (args["positionMs"] as? NSNumber)?.intValue ?? 0)
    let maxSide = min(max((args["maxSide"] as? NSNumber)?.intValue ?? 512, 16), 4096)
    Task {
      let frame = await VideoCompositorPlugin.frame(path, positionMs: position, maxSide: maxSide)
      DispatchQueue.main.async {
        if let frame = frame {
          result(frame)
        } else {
          result(FlutterError(code: "frame", message: "NEFORUM could not read a frame of this video.", details: nil))
        }
      }
    }
  }

  /// An upright PNG of the frame near [positionMs], at most [maxSide] on its
  /// longest side; nil when the file has no readable video.
  static func frame(_ path: String, positionMs: Int, maxSide: Int) async -> [String: Any]? {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    // A square box: the upright picture fits it whichever way it is turned.
    generator.maximumSize = CGSize(width: maxSide, height: maxSide)
    let tolerance = CMTime(value: 1, timescale: 10)
    generator.requestedTimeToleranceBefore = tolerance
    generator.requestedTimeToleranceAfter = tolerance
    var time = CMTime(value: CMTimeValue(positionMs), timescale: 1000)
    if let duration = try? await asset.load(.duration), duration.isNumeric, duration > .zero, time >= duration {
      // The last frame starts before the end.
      time = CMTimeMaximum(.zero, CMTimeSubtract(duration, tolerance))
    }
    do {
      let image: CGImage
      var actual = time
      if #available(iOS 16, macOS 13, *) {
        let (generatedImage, generatedTime) = try await generator.image(at: time)
        image = generatedImage
        actual = generatedTime
      } else {
        image = try generator.copyCGImage(at: time, actualTime: &actual)
      }
      guard let png = pngData(image) else { return nil }
      return [
        "png": FlutterStandardTypedData(bytes: png),
        "width": image.width,
        "height": image.height,
        "positionMs": actual.isNumeric ? max(0, Int((actual.seconds * 1000).rounded())) : positionMs,
      ]
    } catch {
      return nil
    }
  }

  private static func pngData(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
  }

  // MARK: Re-encoding

  private func transcode(_ args: [String: Any], _ result: @escaping FlutterResult) {
    func int(_ key: String) -> Int { (args[key] as? NSNumber)?.intValue ?? 0 }
    let input = args["inputPath"] as? String ?? ""
    let output = args["outputPath"] as? String ?? ""
    let videoBitrate = int("videoBitrate")
    let audioBitrate = int("audioBitrate")
    let maxSide = int("maxSide")
    guard !input.isEmpty, !output.isEmpty, input != output, videoBitrate > 0, (16...4096).contains(maxSide) else {
      result(FlutterError(code: "args", message: "The video request is not complete.", details: nil))
      return
    }
    startJob(id: int("id"), code: "transcode", result: result) {
      try await MediaWriterJob.transcode(
        input: URL(fileURLWithPath: input), output: URL(fileURLWithPath: output),
        videoBitrate: videoBitrate, audioBitrate: audioBitrate, maxSide: maxSide)
    }
  }

  private func audioVideo(_ args: [String: Any], _ result: @escaping FlutterResult) {
    func int(_ key: String) -> Int { (args[key] as? NSNumber)?.intValue ?? 0 }
    let audio = args["audioPath"] as? String ?? ""
    let output = args["outputPath"] as? String ?? ""
    let png = (args["imagePng"] as? FlutterStandardTypedData)?.data
    let width = int("frameWidth")
    let height = int("frameHeight")
    let audioBitrate = int("audioBitrate")
    let frameOk = (16...4096).contains(width) && (16...4096).contains(height) && width % 2 == 0 && height % 2 == 0
    guard frameOk, !audio.isEmpty, !output.isEmpty, audio != output else {
      result(FlutterError(code: "args", message: "The video request is not complete.", details: nil))
      return
    }
    guard let data = png, let image = VideoCompositorPlugin.image(from: data) else {
      result(FlutterError(code: "audioVideo", message: "The picture could not be read.", details: nil))
      return
    }
    startJob(id: int("id"), code: "audioVideo", result: result) {
      try await MediaWriterJob.audioVideo(
        audio: URL(fileURLWithPath: audio), output: URL(fileURLWithPath: output), image: image,
        frame: CGSize(width: width, height: height), audioBitrate: audioBitrate)
    }
  }

  private func transcodeAudio(_ args: [String: Any], _ result: @escaping FlutterResult) {
    func int(_ key: String) -> Int { (args[key] as? NSNumber)?.intValue ?? 0 }
    let input = args["inputPath"] as? String ?? ""
    let output = args["outputPath"] as? String ?? ""
    let format = args["format"] as? String ?? ""
    let bitrate = int("bitrate")
    if format == "mp3" {
      result(FlutterError(code: "unsupported", message: "This device cannot write MP3 files.", details: nil))
      return
    }
    guard format == "m4a", !input.isEmpty, !output.isEmpty, input != output else {
      result(FlutterError(code: "args", message: "The sound request is not complete.", details: nil))
      return
    }
    startJob(id: int("id"), code: "transcodeAudio", result: result) {
      try await MediaWriterJob.transcodeAudio(
        input: URL(fileURLWithPath: input), output: URL(fileURLWithPath: output), bitrate: bitrate)
    }
  }

  /// Prepares a job off the main thread, then runs it; failures report [code].
  private func startJob(
    id: Int, code: String, result: @escaping FlutterResult, prepare: @escaping () async throws -> MediaWriterJob
  ) {
    guard session == nil, job == nil else {
      result(FlutterError(code: "busy", message: "Another video is being made.", details: nil))
      return
    }
    Task {
      do {
        let job = try await prepare()
        DispatchQueue.main.async { self.run(job, id: id, code: code, result: result) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: code, message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private func run(_ job: MediaWriterJob, id: Int, code: String, result: @escaping FlutterResult) {
    guard session == nil, self.job == nil else {
      result(FlutterError(code: "busy", message: "Another video is being made.", details: nil))
      return
    }
    self.job = job
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      guard let self = self, let job = self.job else { return }
      self.channel.invokeMethod("progress", arguments: ["id": id, "progress": job.progress])
    }
    RunLoop.main.add(timer, forMode: .common)
    progressTimer = timer
    #if os(iOS)
    // As for compose: when iOS ends the extra time, the job is cancelled.
    var backgroundTask = UIBackgroundTaskIdentifier.invalid
    func endBackgroundTask() {
      guard backgroundTask != .invalid else { return }
      UIApplication.shared.endBackgroundTask(backgroundTask)
      backgroundTask = .invalid
    }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "NEFORUM video") {
      job.cancel()
      endBackgroundTask()
    }
    #endif
    job.start { [weak self] error in
      DispatchQueue.main.async {
        self?.progressTimer?.invalidate()
        self?.progressTimer = nil
        self?.job = nil
        #if os(iOS)
        endBackgroundTask()
        #endif
        guard let error = error else {
          result(nil)
          return
        }
        result(FlutterError(
          code: error is JobCancellation ? "cancelled" : code, message: error.localizedDescription, details: nil))
      }
    }
  }
}

struct CompositionError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

/// Why a [MediaWriterJob] stopped early: iOS ended its background time.
struct JobCancellation: LocalizedError {
  var errorDescription: String? { "The file was not finished: NEFORUM was in the background too long." }
}

/// One re-encode with AVAssetReader and AVAssetWriter. Each writer input has
/// a [Feed] (decoded samples from a reader, or a still picture repeated), and
/// every feed runs on one serial queue, so stopping never races an append.
/// A failed or cancelled job leaves no file behind.
final class MediaWriterJob {
  /// Appends the next sample to [input] and returns its time; nil once the
  /// source has ended.
  struct Feed {
    let input: AVAssetWriterInput
    let appendNext: () throws -> CMTime?
  }

  /// Still pictures are written at a rate every network accepts.
  static let stillFrameRate: Int32 = 30

  private let writer: AVAssetWriter
  private let readers: [AVAssetReader]
  private let feeds: [Feed]
  private let duration: CMTime
  /// Where the file ends when it is not the end of the last sample.
  private let sessionEnd: CMTime?
  private let queue = DispatchQueue(label: "org.neforum.video.write")
  /// Queue only: set while the job runs, nil once it has reported.
  private var completion: ((Error?) -> Void)?
  private var unfinishedFeeds = 0
  private var finishing = false
  private let lock = NSLock()
  /// The latest sample time written; under [lock].
  private var written = CMTime.zero

  init(writer: AVAssetWriter, readers: [AVAssetReader], feeds: [Feed], duration: CMTime, sessionEnd: CMTime? = nil) {
    self.writer = writer
    self.readers = readers
    self.feeds = feeds
    self.duration = duration
    self.sessionEnd = sessionEnd
  }

  /// From 0 to 1; any thread.
  var progress: Double {
    lock.lock()
    defer { lock.unlock() }
    guard duration.isNumeric, duration.seconds > 0, written.isNumeric else { return 0 }
    return min(1, max(0, written.seconds / duration.seconds))
  }

  /// Runs the job; [completion] is called once, on the job's queue.
  func start(_ completion: @escaping (Error?) -> Void) {
    queue.async {
      self.completion = completion
      guard self.writer.startWriting() else {
        self.stop(self.writer.error ?? CompositionError("The new file could not be written."))
        return
      }
      for reader in self.readers {
        guard reader.startReading() else {
          self.stop(reader.error ?? CompositionError("The file could not be read."))
          return
        }
      }
      self.writer.startSession(atSourceTime: .zero)
      self.unfinishedFeeds = self.feeds.count
      for feed in self.feeds {
        var ended = false
        feed.input.requestMediaDataWhenReady(on: self.queue) { [weak self] in
          guard let self = self else { return }
          while !ended, self.completion != nil, feed.input.isReadyForMoreMediaData {
            do {
              guard let time = try feed.appendNext() else {
                ended = true
                feed.input.markAsFinished()
                self.feedEnded()
                break
              }
              self.advance(to: time)
            } catch {
              self.stop(error)
            }
          }
        }
      }
    }
  }

  /// Stops the job; it reports [JobCancellation]. Any thread.
  func cancel() {
    queue.async { self.stop(JobCancellation()) }
  }

  private func advance(to time: CMTime) {
    guard time.isNumeric else { return }
    lock.lock()
    if time > written { written = time }
    lock.unlock()
  }

  private func feedEnded() {
    unfinishedFeeds -= 1
    guard unfinishedFeeds == 0, completion != nil else { return }
    finishing = true
    if let end = sessionEnd { writer.endSession(atSourceTime: end) }
    writer.finishWriting {
      self.queue.async {
        guard let completion = self.completion else { return }
        self.completion = nil
        if self.writer.status == .completed {
          completion(nil)
        } else {
          try? FileManager.default.removeItem(at: self.writer.outputURL)
          completion(self.writer.error ?? CompositionError("The new file could not be finished."))
        }
      }
    }
  }

  private func stop(_ error: Error) {
    // Once the writer is finishing, it reports for itself.
    guard let completion = completion, !finishing else { return }
    self.completion = nil
    for reader in readers where reader.status == .reading {
      reader.cancelReading()
    }
    if writer.status == .writing { writer.cancelWriting() }
    try? FileManager.default.removeItem(at: writer.outputURL)
    completion(error)
  }

  // MARK: Jobs

  /// [input] as H.264 at [videoBitrate] (scaled so its longest shown side is
  /// at most [maxSide], turned upright) and its sound as AAC.
  static func transcode(
    input: URL, output: URL, videoBitrate: Int, audioBitrate: Int, maxSide: Int
  ) async throws -> MediaWriterJob {
    let asset = AVURLAsset(url: input)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw CompositionError("This file has no video.")
    }
    let (natural, transform, frameRate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
    let duration = try await asset.load(.duration)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    guard duration.isNumeric, duration > .zero else { throw CompositionError("This video has no length.") }
    guard natural.width > 0, natural.height > 0 else { throw CompositionError("This video has no picture.") }

    // The picture as shown, then scaled down to the even size the encoder takes.
    let upright = CGRect(origin: .zero, size: natural).applying(transform)
    let scale = min(1, CGFloat(maxSide) / max(upright.width, upright.height))
    let size = CGSize(
      width: evenSide(upright.width * scale, limit: maxSide), height: evenSide(upright.height * scale, limit: maxSide))

    let composition = AVMutableVideoComposition()
    composition.renderSize = size
    let rate = frameRate > 0 && frameRate <= 120 ? Double(frameRate) : 30
    composition.frameDuration = CMTime(value: CMTimeValue((600 / rate).rounded()), timescale: 600)
    composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
    composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
    composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
    layer.setTransform(
      transform
        .concatenating(CGAffineTransform(translationX: -upright.minX, y: -upright.minY))
        .concatenating(CGAffineTransform(scaleX: size.width / upright.width, y: size.height / upright.height)),
      at: .zero)
    instruction.layerInstructions = [layer]
    composition.instructions = [instruction]

    try? FileManager.default.removeItem(at: output)
    let reader = try AVAssetReader(asset: asset)
    let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true
    let frames = AVAssetReaderVideoCompositionOutput(
      videoTracks: [track], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    frames.videoComposition = composition
    frames.alwaysCopiesSampleData = false
    guard reader.canAdd(frames) else { throw CompositionError("This video cannot be read.") }
    reader.add(frames)
    let video = try h264Input(size: size, bitrate: videoBitrate, writer: writer)
    var feeds = [copying(frames, of: reader, into: video, of: writer)]
    if !audioTracks.isEmpty {
      feeds.append(try await aacFeed(tracks: audioTracks, reader: reader, writer: writer, bitrate: audioBitrate))
    }
    return MediaWriterJob(writer: writer, readers: [reader], feeds: feeds, duration: duration)
  }

  /// An MP4 of [image] (stretched to [frame]) for the length of the sound
  /// at [audio], with that sound as AAC.
  static func audioVideo(
    audio: URL, output: URL, image: CGImage, frame: CGSize, audioBitrate: Int
  ) async throws -> MediaWriterJob {
    let asset = AVURLAsset(url: audio)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let duration = try await asset.load(.duration)
    guard !tracks.isEmpty else { throw CompositionError("This file has no sound.") }
    guard duration.isNumeric, duration > .zero else { throw CompositionError("This sound has no length.") }
    let picture = try pixelBuffer(of: image, size: frame)

    try? FileManager.default.removeItem(at: output)
    let reader = try AVAssetReader(asset: asset)
    let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true
    // A still picture costs little at any bitrate; a key frame every two
    // seconds keeps seeking quick.
    let video = try h264Input(
      size: frame, bitrate: max(500_000, Int(frame.width * frame.height) * 2),
      keyFrameInterval: Int(stillFrameRate) * 2, writer: writer)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
    let frameRate = stillFrameRate
    var index: CMTimeValue = 0
    let still = Feed(input: video) {
      let time = CMTime(value: index, timescale: frameRate)
      guard time < duration else { return nil }
      guard adaptor.append(picture, withPresentationTime: time) else {
        throw writer.error ?? CompositionError("The new file could not be written.")
      }
      index += 1
      return time
    }
    let sound = try await aacFeed(tracks: tracks, reader: reader, writer: writer, bitrate: audioBitrate)
    // The picture stays until the sound ends.
    return MediaWriterJob(
      writer: writer, readers: [reader], feeds: [still, sound], duration: duration, sessionEnd: duration)
  }

  /// The sound of [input] as an AAC .m4a at [bitrate].
  static func transcodeAudio(input: URL, output: URL, bitrate: Int) async throws -> MediaWriterJob {
    let asset = AVURLAsset(url: input)
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    let duration = try await asset.load(.duration)
    guard !tracks.isEmpty else { throw CompositionError("This file has no sound.") }
    guard duration.isNumeric, duration > .zero else { throw CompositionError("This sound has no length.") }

    try? FileManager.default.removeItem(at: output)
    let reader = try AVAssetReader(asset: asset)
    let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
    writer.shouldOptimizeForNetworkUse = true
    let sound = try await aacFeed(tracks: tracks, reader: reader, writer: writer, bitrate: bitrate)
    return MediaWriterJob(writer: writer, readers: [reader], feeds: [sound], duration: duration)
  }

  // MARK: Pieces

  /// [value] rounded down to an even side from 2 to [limit].
  private static func evenSide(_ value: CGFloat, limit: Int) -> Int {
    let side = Swift.min(Int(value.rounded()), limit)
    return Swift.max(2, side - side % 2)
  }

  /// An H.264 input of [size] at an average of [bitrate], in standard
  /// dynamic range BT.709.
  private static func h264Input(
    size: CGSize, bitrate: Int, keyFrameInterval: Int? = nil, writer: AVAssetWriter
  ) throws -> AVAssetWriterInput {
    var compression: [String: Any] = [
      AVVideoAverageBitRateKey: bitrate,
      AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
    ]
    if let interval = keyFrameInterval { compression[AVVideoMaxKeyFrameIntervalKey] = interval }
    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(size.width),
      AVVideoHeightKey: Int(size.height),
      AVVideoCompressionPropertiesKey: compression,
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
    ]
    guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
      throw CompositionError("This video size cannot be encoded on this device.")
    }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else { throw CompositionError("The new file cannot take a video.") }
    writer.add(input)
    return input
  }

  /// Every track in [tracks] mixed to stereo PCM by [reader], written by
  /// [writer] as AAC at [bitrate] (kept to what the encoder takes for stereo).
  private static func aacFeed(
    tracks: [AVAssetTrack], reader: AVAssetReader, writer: AVAssetWriter, bitrate: Int
  ) async throws -> Feed {
    let formats = try await tracks[0].load(.formatDescriptions)
    let sourceRate = formats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 0
    // AAC takes 44.1 or 48 kHz; other rates are resampled to the nearer family.
    let rate: Double = sourceRate > 0 && Int(sourceRate) % 11025 == 0 ? 44100 : 48000
    let pcm: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: rate,
      AVNumberOfChannelsKey: 2,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: pcm)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw CompositionError("This sound cannot be read.") }
    reader.add(output)
    let aac: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: rate,
      AVNumberOfChannelsKey: 2,
      AVEncoderBitRateKey: min(max(bitrate, 64_000), 320_000),
    ]
    guard writer.canApply(outputSettings: aac, forMediaType: .audio) else {
      throw CompositionError("This sound cannot be encoded on this device.")
    }
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else { throw CompositionError("The new file cannot take sound.") }
    writer.add(input)
    return copying(output, of: reader, into: input, of: writer)
  }

  /// Copies the samples of [output] (added to [reader]) into [input].
  private static func copying(
    _ output: AVAssetReaderOutput, of reader: AVAssetReader, into input: AVAssetWriterInput, of writer: AVAssetWriter
  ) -> Feed {
    Feed(input: input) {
      guard let sample = output.copyNextSampleBuffer() else {
        if reader.status == .failed { throw reader.error ?? CompositionError("The file could not be read.") }
        return nil
      }
      guard input.append(sample) else { throw writer.error ?? CompositionError("The new file could not be written.") }
      return CMSampleBufferGetPresentationTimeStamp(sample)
    }
  }

  /// [image] stretched over a [size] BGRA buffer the encoder can read
  /// directly; transparent parts show black.
  private static func pixelBuffer(of image: CGImage, size: CGSize) throws -> CVPixelBuffer {
    let width = Int(size.width)
    let height = Int(size.height)
    let attributes: [String: Any] = [
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ]
    var created: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &created)
      == kCVReturnSuccess, let buffer = created
    else { throw CompositionError("The picture could not be prepared.") }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { throw CompositionError("The picture could not be prepared.") }
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(rect)
    context.interpolationQuality = .high
    context.draw(image, in: rect)
    return buffer
  }
}

/// What [CaptionCompositor] needs for every frame, prepared once.
final class CaptionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
  let timeRange: CMTimeRange
  let enablePostProcessing = false
  let containsTweening = false
  let requiredSourceTrackIDs: [NSValue]?
  let passthroughTrackID = kCMPersistentTrackID_Invalid

  let trackID: CMPersistentTrackID
  let orientation: CGImagePropertyOrientation
  /// The frame in Core Image coordinates (origin bottom left).
  let frameRect: CGRect
  /// The video rectangle, given from the top left.
  let video: CGRect
  let background: CIImage
  let overlay: CIImage

  init(
    timeRange: CMTimeRange, trackID: CMPersistentTrackID, orientation: CGImagePropertyOrientation,
    frame: CGSize, video: CGRect, background: CIColor, overlay: CGImage
  ) {
    let frameRect = CGRect(origin: .zero, size: frame)
    self.timeRange = timeRange
    self.trackID = trackID
    self.requiredSourceTrackIDs = [NSNumber(value: trackID)]
    self.orientation = orientation
    self.frameRect = frameRect
    self.video = video
    self.background = CIImage(color: background).cropped(to: frameRect)
    let caption = CIImage(cgImage: overlay)
    self.overlay = caption.transformed(
      by: CGAffineTransform(scaleX: frame.width / caption.extent.width, y: frame.height / caption.extent.height))
    super.init()
  }

  /// The source frame upright and stretched into the video rectangle.
  func place(_ source: CIImage) -> CIImage {
    let upright = source.oriented(orientation)
    let shown = upright.extent
    let flippedTop = frameRect.height - video.maxY
    return upright.transformed(
      by: CGAffineTransform(translationX: -shown.minX, y: -shown.minY)
        .concatenating(CGAffineTransform(scaleX: video.width / shown.width, y: video.height / shown.height))
        .concatenating(CGAffineTransform(translationX: video.minX, y: flippedTop)))
  }
}

/// Draws each output frame: background, the placed picture, the caption.
final class CaptionCompositor: NSObject, AVVideoCompositing {
  let sourcePixelBufferAttributes: [String: Any]? = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
  let requiredPixelBufferAttributesForRenderContext: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
  ]

  private let context = CIContext(options: [.cacheIntermediates: false])
  private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
  private let renderQueue = DispatchQueue(label: "org.neforum.video.render")
  /// Set while AVFoundation cancels the pending requests; render queue only.
  private var cancelling = false

  func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

  func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
    renderQueue.async {
      if self.cancelling {
        request.finishCancelledRequest()
        return
      }
      guard let instruction = request.videoCompositionInstruction as? CaptionInstruction,
            let output = request.renderContext.newPixelBuffer() else {
        request.finish(with: CompositionError("A video frame could not be drawn."))
        return
      }
      var image = instruction.background
      // After the end of the picture (a longer sound track), the background stays.
      if let source = request.sourceFrame(byTrackID: instruction.trackID) {
        image = instruction.place(CIImage(cvPixelBuffer: source)).composited(over: image)
      }
      image = instruction.overlay.composited(over: image)
      self.context.render(image, to: output, bounds: instruction.frameRect, colorSpace: self.colorSpace)
      request.finish(withComposedVideoFrame: output)
    }
  }

  func cancelAllPendingVideoCompositionRequests() {
    renderQueue.sync { cancelling = true }
    renderQueue.async { self.cancelling = false }
  }
}
