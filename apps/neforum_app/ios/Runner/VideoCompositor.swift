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
final class VideoCompositorPlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  /// The export in progress (Dart sends one at a time); main thread only.
  private var session: AVAssetExportSession?
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
    guard session == nil else {
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
    guard self.session == nil else {
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
}

struct CompositionError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
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
