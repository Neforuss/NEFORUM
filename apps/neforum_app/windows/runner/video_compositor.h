#ifndef RUNNER_VIDEO_COMPOSITOR_H_
#define RUNNER_VIDEO_COMPOSITOR_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <windows.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// What ProbeVideoFile reads from a video file.
struct VideoFileProbe {
  // The picture size as stored, before |rotation|.
  int width = 0;
  int height = 0;
  // Clockwise degrees (0, 90, 180, 270) players turn the picture to show it
  // upright: phones store portrait video as a landscape frame with 90.
  int rotation = 0;
  int64_t duration_ms = 0;
  bool has_audio = false;
};

// One composition (lib/platform/video_compositor.dart): a frame_width x
// frame_height H.264/AAC MP4 filled with |background_rgb|, the video turned
// upright and stretched into the video rectangle (the Dart side picks a
// rectangle with the video's aspect), its sound, and |overlay_png| drawn over
// the whole frame.
struct VideoCompositionRequest {
  std::wstring input_path;
  std::wstring output_path;
  std::vector<uint8_t> overlay_png;
  int frame_width = 0;
  int frame_height = 0;
  int video_left = 0;
  int video_top = 0;
  int video_width = 0;
  int video_height = 0;
  uint32_t background_rgb = 0;
};

// Whether Media Foundation with an H.264 and an AAC encoder is available.
// Windows N editions without the Media Feature Pack have none of it.
bool VideoCompositionSupported();

// Reads the picture size, rotation, duration and whether there is sound.
// Returns false with |error| set when the file cannot be read.
bool ProbeVideoFile(const std::wstring& path, VideoFileProbe* probe,
                    std::string* error);

// Writes the composed MP4, frame by frame: Media Foundation decodes and
// encodes, Direct2D draws each frame on a WIC bitmap. |progress| receives
// values from 0 to 1 on the calling thread; |cancelled| stops early. Returns
// false with |error_code| and |error| set, and no output file, on failure.
bool ComposeVideoFile(const VideoCompositionRequest& request,
                      const std::function<void(double)>& progress,
                      const std::atomic<bool>& cancelled,
                      std::string* error_code, std::string* error);

// "neforum/video": the video caption compositor
// (lib/platform/video_compositor.dart). Every call runs on a worker thread;
// results and "progress" calls go back to Dart on the platform thread through
// a message-only window.
class VideoCompositor {
 public:
  explicit VideoCompositor(flutter::BinaryMessenger* messenger);
  ~VideoCompositor();

  VideoCompositor(const VideoCompositor&) = delete;
  VideoCompositor& operator=(const VideoCompositor&) = delete;

 private:
  struct Job;
  using Progress = std::function<void(double)>;
  using Work = std::function<void(Job& job, const Progress& progress)>;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Runs |work| on a new thread; its outcome answers |result|. |dart_id|
  // identifies the composition in "progress" calls (0: none).
  void Start(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result,
      int64_t dart_id, Work work);

  // On the platform thread, when the job's thread is done.
  void Finish(int job_id);
  void ReportProgress(int job_id, int permille);

  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_ = nullptr;
  std::mutex mutex_;
  std::map<int, std::unique_ptr<Job>> jobs_;
  int last_job_ = 0;
  // Set when NEFORUM closes: running compositions stop.
  std::atomic<bool> closing_{false};
};

#endif  // RUNNER_VIDEO_COMPOSITOR_H_
