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
// the whole frame. Without an overlay nothing is drawn on top (transcoding).
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
  // Average video bitrate in bits per second, held constant (0: about 0.12
  // bits per pixel per frame, the encoder's own rate control).
  uint32_t video_bitrate = 0;
  // AAC bitrate in bits per second (0: 192 kbit/s stereo, 128 kbit/s mono).
  uint32_t audio_bitrate = 0;
};

// One still frame read by ReadVideoFrame: a PNG, upright.
struct VideoFrameImage {
  std::vector<uint8_t> png;
  int width = 0;
  int height = 0;
  int64_t position_ms = 0;
};

// A re-encoded copy of a video (transcode): H.264/AAC MP4 at an average
// video bitrate, scaled down so that its longest shown side is at most
// |max_side|.
struct VideoTranscodeRequest {
  std::wstring input_path;
  std::wstring output_path;
  uint32_t video_bitrate = 0;
  uint32_t audio_bitrate = 0;
  int max_side = 1920;
};

// A video of one still picture for the whole length of a sound file
// (audioVideo): |image_png| fills the frame_width x frame_height frame.
struct StillVideoRequest {
  std::wstring audio_path;
  std::wstring output_path;
  std::vector<uint8_t> image_png;
  int frame_width = 0;
  int frame_height = 0;
  uint32_t audio_bitrate = 0;
};

// A sound file converted to "mp3" or "m4a" (transcodeAudio).
struct AudioTranscodeRequest {
  std::wstring input_path;
  std::wstring output_path;
  std::string format;
  uint32_t bitrate = 0;
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

// Decodes the frame shown at |position_ms| (the Source Reader seeks to the
// key frame before it and decodes forward), turns it upright and scales it so
// its longest side is at most |max_side|, as a PNG made by WIC.
bool ReadVideoFrame(const std::wstring& path, int64_t position_ms,
                    int max_side, VideoFrameImage* frame, std::string* error);

// Re-encodes a video through ComposeVideoFile with the whole frame given to
// the video. Same failure contract.
bool TranscodeVideoFile(const VideoTranscodeRequest& request,
                        const std::function<void(double)>& progress,
                        const std::atomic<bool>& cancelled,
                        std::string* error_code, std::string* error);

// Writes an H.264/AAC MP4 of the still picture at 30 frames per second for as
// long as the sound lasts. Media Foundation decodes MP3, WAV, FLAC, AAC and
// ALAC. Same failure contract as ComposeVideoFile.
bool RenderStillVideoFile(const StillVideoRequest& request,
                          const std::function<void(double)>& progress,
                          const std::atomic<bool>& cancelled,
                          std::string* error_code, std::string* error);

// The formats TranscodeAudioFile can write here: "m4a" with an AAC encoder,
// "mp3" with an MP3 encoder (Windows 8 and later have one).
std::vector<std::string> AudioOutputFormats();

// Converts a sound file to MP3 or AAC in an M4A. Same failure contract as
// ComposeVideoFile.
bool TranscodeAudioFile(const AudioTranscodeRequest& request,
                        const std::function<void(double)>& progress,
                        const std::atomic<bool>& cancelled,
                        std::string* error_code, std::string* error);

// "neforum/video": the video caption compositor and video tools
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
