#include "video_compositor.h"

#include <codecapi.h>
#include <d2d1.h>
#include <flutter/standard_method_codec.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <utility>

namespace {

using Microsoft::WRL::ComPtr;

constexpr wchar_t kWindowClass[] = L"NeforumVideoCompositor";
constexpr UINT kDoneMessage = WM_APP + 0x61;
constexpr UINT kProgressMessage = WM_APP + 0x62;

// Media Foundation time: 100-nanosecond units.
constexpr LONGLONG kTicksPerSecond = 10000000;
constexpr DWORD kNoStream = MAXDWORD;

// mfplat.dll and mfreadwrite.dll are delay-loaded (CMakeLists.txt): Windows N
// editions without the Media Feature Pack lack them, and NEFORUM must start
// there anyway. Nothing calls into them before this says they are present.
bool MediaFoundationPresent() {
  static const bool present = [] {
    const HMODULE platform =
        LoadLibraryExW(L"mfplat.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    const HMODULE readwrite = LoadLibraryExW(L"mfreadwrite.dll", nullptr,
                                             LOAD_LIBRARY_SEARCH_SYSTEM32);
    return platform != nullptr && readwrite != nullptr;
  }();
  return present;
}

// COM (multithreaded) and Media Foundation for the calling thread.
class MediaFoundationScope {
 public:
  MediaFoundationScope() {
    // S_FALSE (already initialized) must be balanced too; a thread that is
    // already single-threaded keeps that and works as well.
    com_initialized_ = SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
    started_ = MediaFoundationPresent() &&
               SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_LITE));
  }
  ~MediaFoundationScope() {
    if (started_) MFShutdown();
    if (com_initialized_) CoUninitialize();
  }
  MediaFoundationScope(const MediaFoundationScope&) = delete;
  MediaFoundationScope& operator=(const MediaFoundationScope&) = delete;

  bool started() const { return started_; }

 private:
  bool com_initialized_ = false;
  bool started_ = false;
};

std::wstring Wide(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                                    static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring out(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()),
                      out.data(), n);
  return out;
}

// "|text| (0x80004005)": the HRESULT helps when a user reports a failure.
std::string WithCode(const char* text, HRESULT hr) {
  char code[16];
  snprintf(code, sizeof(code), "0x%08lX", static_cast<unsigned long>(hr));
  return std::string(text) + " (" + code + ")";
}

bool EncoderAvailable(const GUID& category, const GUID& major,
                      const GUID& subtype) {
  MFT_REGISTER_TYPE_INFO output = {major, subtype};
  IMFActivate** activates = nullptr;
  UINT32 count = 0;
  if (FAILED(MFTEnumEx(category,
                       MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT |
                           MFT_ENUM_FLAG_SORTANDFILTER,
                       nullptr, &output, &activates, &count))) {
    return false;
  }
  for (UINT32 i = 0; i < count; i++) activates[i]->Release();
  CoTaskMemFree(activates);
  return count > 0;
}

struct StreamIndices {
  DWORD video = kNoStream;
  DWORD audio = kNoStream;
};

// The first video and the first audio stream of the file.
StreamIndices FindStreams(IMFSourceReader* reader) {
  StreamIndices out;
  for (DWORD i = 0; i < 64; i++) {
    ComPtr<IMFMediaType> type;
    const HRESULT hr = reader->GetNativeMediaType(i, 0, &type);
    if (hr == MF_E_INVALIDSTREAMNUMBER) break;
    GUID major = GUID_NULL;
    if (FAILED(hr) || FAILED(type->GetGUID(MF_MT_MAJOR_TYPE, &major))) continue;
    if (major == MFMediaType_Video && out.video == kNoStream) out.video = i;
    if (major == MFMediaType_Audio && out.audio == kNoStream) out.audio = i;
  }
  return out;
}

// The picture inside a decoded frame: decoders pad H.264 frames to whole
// macroblocks (1920x1088 for 1080p) and name the shown part an aperture.
RECT PictureArea(IMFMediaType* type, UINT32 width, UINT32 height) {
  for (const GUID& key : {MF_MT_MINIMUM_DISPLAY_APERTURE, MF_MT_GEOMETRIC_APERTURE}) {
    MFVideoArea area = {};
    if (FAILED(type->GetBlob(key, reinterpret_cast<UINT8*>(&area), sizeof(area),
                             nullptr))) {
      continue;
    }
    const LONG left = area.OffsetX.value;
    const LONG top = area.OffsetY.value;
    if (area.Area.cx > 0 && area.Area.cy > 0 && left >= 0 && top >= 0 &&
        left + area.Area.cx <= static_cast<LONG>(width) &&
        top + area.Area.cy <= static_cast<LONG>(height)) {
      return RECT{left, top, left + area.Area.cx, top + area.Area.cy};
    }
  }
  return RECT{0, 0, static_cast<LONG>(width), static_cast<LONG>(height)};
}

// MF_MT_VIDEO_ROTATION is how far the stored picture is turned
// counter-clockwise, which is how far players turn it clockwise to show it.
int RotationOf(IMFMediaType* type) {
  const UINT32 rotation = MFGetAttributeUINT32(type, MF_MT_VIDEO_ROTATION, 0);
  return rotation == 90 || rotation == 180 || rotation == 270
             ? static_cast<int>(rotation)
             : 0;
}

// The length of the reader's file (0 when it does not say).
LONGLONG DurationOf(IMFSourceReader* reader) {
  LONGLONG out = 0;
  PROPVARIANT duration;
  PropVariantInit(&duration);
  if (SUCCEEDED(reader->GetPresentationAttribute(
          static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION,
          &duration)) &&
      duration.vt == VT_UI8) {
    out = static_cast<LONGLONG>(duration.uhVal.QuadPart);
  }
  PropVariantClear(&duration);
  return out;
}

// Asks the reader for |stream| as 16-bit PCM at 44.1 or 48 kHz, mono or
// stereo: what the AAC and MP3 encoders take. Since Windows 8 the reader
// resamples and mixes down itself (22.05 kHz MP3s, 96 kHz FLAC, 5.1 sound).
bool SelectPcmAudio(IMFSourceReader* reader, DWORD stream, ComPtr<IMFMediaType>* type,
                    UINT32* rate, UINT32* channels, std::string* error) {
  ComPtr<IMFMediaType> native;
  HRESULT hr = reader->GetNativeMediaType(stream, 0, &native);
  if (FAILED(hr)) {
    *error = WithCode("The sound could not be read.", hr);
    return false;
  }
  const UINT32 native_rate = MFGetAttributeUINT32(native.Get(), MF_MT_AUDIO_SAMPLES_PER_SECOND, 0);
  const UINT32 native_channels = MFGetAttributeUINT32(native.Get(), MF_MT_AUDIO_NUM_CHANNELS, 0);
  const UINT32 wanted_rate = native_rate == 48000 ? 48000
                             : native_rate != 0 && native_rate % 11025 == 0 ? 44100
                                                                             : 48000;
  const UINT32 wanted_channels = native_channels == 1 ? 1 : 2;

  ComPtr<IMFMediaType> pcm;
  hr = MFCreateMediaType(&pcm);
  if (SUCCEEDED(hr)) hr = pcm->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  if (SUCCEEDED(hr)) hr = pcm->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  if (SUCCEEDED(hr)) hr = pcm->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  if (SUCCEEDED(hr)) hr = pcm->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, wanted_rate);
  if (SUCCEEDED(hr)) hr = pcm->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, wanted_channels);
  if (SUCCEEDED(hr)) hr = pcm->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, wanted_channels * 2);
  if (SUCCEEDED(hr)) hr = pcm->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, wanted_rate * wanted_channels * 2);
  if (SUCCEEDED(hr)) hr = reader->SetCurrentMediaType(stream, nullptr, pcm.Get());
  if (FAILED(hr)) {
    // The decoder may only give its own rate and channels: those are
    // checked below.
    ComPtr<IMFMediaType> partial;
    hr = MFCreateMediaType(&partial);
    if (SUCCEEDED(hr)) hr = partial->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    if (SUCCEEDED(hr)) hr = partial->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
    if (SUCCEEDED(hr)) hr = partial->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    if (SUCCEEDED(hr)) hr = reader->SetCurrentMediaType(stream, nullptr, partial.Get());
  }
  if (SUCCEEDED(hr)) hr = reader->GetCurrentMediaType(stream, type->ReleaseAndGetAddressOf());
  if (FAILED(hr)) {
    *error = WithCode("The sound could not be read.", hr);
    return false;
  }
  *rate = MFGetAttributeUINT32(type->Get(), MF_MT_AUDIO_SAMPLES_PER_SECOND, 0);
  *channels = MFGetAttributeUINT32(type->Get(), MF_MT_AUDIO_NUM_CHANNELS, 0);
  if ((*rate != 44100 && *rate != 48000) || *channels < 1 || *channels > 2 ||
      MFGetAttributeUINT32(type->Get(), MF_MT_AUDIO_BITS_PER_SAMPLE, 0) != 16) {
    *error = "Windows cannot convert this sound on this PC.";
    return false;
  }
  return true;
}

// The AAC encoder takes 12000, 16000, 20000 or 24000 bytes per second (96 to
// 192 kbit/s): the largest that is not above |bits_per_second|; 0 picks 192
// kbit/s for stereo and 128 kbit/s for mono.
UINT32 AacBytesPerSecond(uint32_t bits_per_second, UINT32 channels) {
  if (bits_per_second == 0) return channels == 1 ? 16000 : 24000;
  const uint32_t bytes = bits_per_second / 8;
  if (bytes >= 24000) return 24000;
  if (bytes >= 20000) return 20000;
  if (bytes >= 16000) return 16000;
  return 12000;
}

HRESULT CreateAacType(UINT32 rate, UINT32 channels, UINT32 bytes_per_second,
                      ComPtr<IMFMediaType>* type) {
  HRESULT hr = MFCreateMediaType(type->ReleaseAndGetAddressOf());
  IMFMediaType* aac = type->Get();
  if (SUCCEEDED(hr)) hr = aac->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  if (SUCCEEDED(hr)) hr = aac->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
  if (SUCCEEDED(hr)) hr = aac->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
  if (SUCCEEDED(hr)) hr = aac->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, rate);
  if (SUCCEEDED(hr)) hr = aac->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, channels);
  if (SUCCEEDED(hr)) hr = aac->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, bytes_per_second);
  return hr;
}

HRESULT CreateH264Type(UINT32 width, UINT32 height, UINT32 rate_numerator,
                       UINT32 rate_denominator, UINT32 bitrate, ComPtr<IMFMediaType>* type) {
  HRESULT hr = MFCreateMediaType(type->ReleaseAndGetAddressOf());
  IMFMediaType* h264 = type->Get();
  if (SUCCEEDED(hr)) hr = h264->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  if (SUCCEEDED(hr)) hr = h264->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  if (SUCCEEDED(hr)) hr = h264->SetUINT32(MF_MT_AVG_BITRATE, bitrate);
  if (SUCCEEDED(hr)) hr = h264->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  if (SUCCEEDED(hr)) hr = h264->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Main);
  if (SUCCEEDED(hr)) hr = MFSetAttributeSize(h264, MF_MT_FRAME_SIZE, width, height);
  if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(h264, MF_MT_FRAME_RATE, rate_numerator, rate_denominator);
  if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(h264, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  return hr;
}

// Top-down BGRX rows, |width| * 4 bytes apart: the frames NEFORUM draws.
HRESULT CreateRgbInputType(UINT32 width, UINT32 height, UINT32 rate_numerator,
                           UINT32 rate_denominator, ComPtr<IMFMediaType>* type) {
  HRESULT hr = MFCreateMediaType(type->ReleaseAndGetAddressOf());
  IMFMediaType* rgb = type->Get();
  if (SUCCEEDED(hr)) hr = rgb->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  if (SUCCEEDED(hr)) hr = rgb->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  if (SUCCEEDED(hr)) hr = rgb->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  if (SUCCEEDED(hr)) hr = rgb->SetUINT32(MF_MT_DEFAULT_STRIDE, width * 4);
  if (SUCCEEDED(hr)) hr = rgb->SetUINT32(MF_MT_FIXED_SIZE_SAMPLES, TRUE);
  if (SUCCEEDED(hr)) hr = rgb->SetUINT32(MF_MT_SAMPLE_SIZE, width * height * 4);
  if (SUCCEEDED(hr)) hr = rgb->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
  if (SUCCEEDED(hr)) hr = MFSetAttributeSize(rgb, MF_MT_FRAME_SIZE, width, height);
  if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(rgb, MF_MT_FRAME_RATE, rate_numerator, rate_denominator);
  if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(rgb, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  return hr;
}

// Encoder settings for IMFSinkWriter::SetInputMediaType: the H.264 encoder
// reads CODECAPI_ values from them. A video bitrate held constant keeps a
// copy made for a size limit under it.
HRESULT ConstantBitrateParameters(UINT32 bitrate, ComPtr<IMFAttributes>* parameters) {
  HRESULT hr = MFCreateAttributes(parameters->ReleaseAndGetAddressOf(), 2);
  if (SUCCEEDED(hr)) {
    hr = (*parameters)->SetUINT32(CODECAPI_AVEncCommonRateControlMode,
                                  eAVEncCommonRateControlMode_CBR);
  }
  if (SUCCEEDED(hr)) hr = (*parameters)->SetUINT32(CODECAPI_AVEncCommonMeanBitRate, bitrate);
  return hr;
}

// Copies a decoded RGB32 frame into |rows|, top-down and |width| * 4 bytes
// apart. |default_stride| is the media type's (negative: bottom-up) for
// buffers without a 2D lock.
bool CopyFrameRows(IMFSample* sample, UINT32 width, UINT32 height, LONG default_stride,
                   std::vector<BYTE>* rows) {
  ComPtr<IMFMediaBuffer> buffer;
  if (FAILED(sample->ConvertToContiguousBuffer(&buffer))) return false;
  const size_t row = static_cast<size_t>(width) * 4;
  rows->resize(row * height);
  const auto copy = [&](const BYTE* top_row, LONG pitch) {
    if (static_cast<size_t>(pitch < 0 ? -pitch : pitch) < row) return false;
    for (UINT32 y = 0; y < height; y++) {
      memcpy(rows->data() + row * y, top_row + static_cast<ptrdiff_t>(y) * pitch, row);
    }
    return true;
  };
  bool copied = false;
  ComPtr<IMF2DBuffer> buffer2d;
  if (SUCCEEDED(buffer.As(&buffer2d))) {
    BYTE* top_row = nullptr;
    LONG pitch = 0;
    if (SUCCEEDED(buffer2d->Lock2D(&top_row, &pitch))) {
      copied = copy(top_row, pitch);
      buffer2d->Unlock2D();
    }
  }
  if (!copied) {
    BYTE* data = nullptr;
    DWORD length = 0;
    if (SUCCEEDED(buffer->Lock(&data, nullptr, &length))) {
      const LONG pitch = default_stride != 0 ? default_stride : static_cast<LONG>(row);
      const size_t needed = static_cast<size_t>(pitch < 0 ? -pitch : pitch) * height;
      if (length >= needed) {
        copied = copy(pitch < 0 ? data + static_cast<size_t>(-pitch) * (height - 1) : data, pitch);
      }
      buffer->Unlock();
    }
  }
  return copied;
}

// Decodes a PNG (or any image WIC reads) scaled to |width| x |height| as
// top-down BGRX rows, |width| * 4 bytes apart.
HRESULT DecodePicture(IWICImagingFactory* wic, const std::vector<uint8_t>& bytes, UINT width,
                      UINT height, BYTE* destination) {
  ComPtr<IWICStream> stream;
  ComPtr<IWICBitmapDecoder> decoder;
  ComPtr<IWICBitmapFrameDecode> frame;
  ComPtr<IWICBitmapScaler> scaler;
  ComPtr<IWICFormatConverter> converter;
  HRESULT hr = wic->CreateStream(&stream);
  if (SUCCEEDED(hr)) {
    hr = stream->InitializeFromMemory(const_cast<BYTE*>(bytes.data()), static_cast<DWORD>(bytes.size()));
  }
  if (SUCCEEDED(hr)) hr = wic->CreateDecoderFromStream(stream.Get(), nullptr, WICDecodeMetadataCacheOnLoad, &decoder);
  if (SUCCEEDED(hr)) hr = decoder->GetFrame(0, &frame);
  UINT source_width = 0;
  UINT source_height = 0;
  if (SUCCEEDED(hr)) hr = frame->GetSize(&source_width, &source_height);
  ComPtr<IWICBitmapSource> source = frame;
  if (SUCCEEDED(hr) && (source_width != width || source_height != height)) {
    hr = wic->CreateBitmapScaler(&scaler);
    if (SUCCEEDED(hr)) hr = scaler->Initialize(frame.Get(), width, height, WICBitmapInterpolationModeFant);
    if (SUCCEEDED(hr)) source = scaler;
  }
  if (SUCCEEDED(hr)) hr = wic->CreateFormatConverter(&converter);
  if (SUCCEEDED(hr)) {
    hr = converter->Initialize(source.Get(), GUID_WICPixelFormat32bppBGR, WICBitmapDitherTypeNone,
                               nullptr, 0.0, WICBitmapPaletteTypeMedianCut);
  }
  if (SUCCEEDED(hr)) hr = converter->CopyPixels(nullptr, width * 4, width * height * 4, destination);
  return hr;
}

// Composes one video. Decoding: a Source Reader giving RGB32 frames and
// 16-bit PCM. Drawing: Direct2D on a WIC bitmap of the output frame (the
// background, the turned and scaled video, the overlay). Encoding: a Sink
// Writer taking RGB32 and PCM and writing H.264 and AAC into an MP4.
class Composer {
 public:
  Composer(const VideoCompositionRequest& request,
           const std::function<void(double)>& progress,
           const std::atomic<bool>& cancelled)
      : request_(request), progress_(progress), cancelled_(cancelled) {}
  Composer(const Composer&) = delete;
  Composer& operator=(const Composer&) = delete;

  bool Run(std::string* code, std::string* message) {
    const bool ok = OpenInput() && ConfigureAudio() && PrepareCanvas() &&
                    OpenOutput() && Process();
    if (!ok) {
      *code = code_;
      *message = message_;
    }
    return ok;
  }

 private:
  bool Fail(const char* code, std::string message) {
    code_ = code;
    message_ = std::move(message);
    return false;
  }

  bool OpenInput() {
    ComPtr<IMFAttributes> attributes;
    HRESULT hr = MFCreateAttributes(&attributes, 1);
    // Colour conversion to RGB32 inside the reader.
    if (SUCCEEDED(hr)) {
      hr = attributes->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
    }
    if (SUCCEEDED(hr)) {
      hr = MFCreateSourceReaderFromURL(request_.input_path.c_str(),
                                       attributes.Get(), &reader_);
    }
    if (FAILED(hr)) return Fail("compose", WithCode("NEFORUM could not open this video.", hr));

    const StreamIndices streams = FindStreams(reader_.Get());
    if (streams.video == kNoStream) return Fail("compose", "This file has no video.");
    video_stream_ = streams.video;
    audio_stream_ = streams.audio;
    reader_->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
    reader_->SetStreamSelection(video_stream_, TRUE);
    if (audio_stream_ != kNoStream) reader_->SetStreamSelection(audio_stream_, TRUE);

    ComPtr<IMFMediaType> native;
    hr = reader_->GetNativeMediaType(video_stream_, 0, &native);
    if (FAILED(hr)) return Fail("compose", WithCode("This video could not be read.", hr));
    rotation_ = RotationOf(native.Get());
    UINT32 numerator = 0;
    UINT32 denominator = 0;
    if (FAILED(MFGetAttributeRatio(native.Get(), MF_MT_FRAME_RATE, &numerator,
                                   &denominator)) ||
        numerator == 0 || denominator == 0 || numerator / denominator > 240) {
      numerator = 30;
      denominator = 1;
    }
    frame_rate_numerator_ = numerator;
    frame_rate_denominator_ = denominator;

    ComPtr<IMFMediaType> rgb;
    hr = MFCreateMediaType(&rgb);
    if (SUCCEEDED(hr)) hr = rgb->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
    if (SUCCEEDED(hr)) hr = rgb->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
    if (SUCCEEDED(hr)) hr = reader_->SetCurrentMediaType(video_stream_, nullptr, rgb.Get());
    if (FAILED(hr)) {
      return Fail("video", WithCode("Windows cannot decode this kind of video on this PC.", hr));
    }
    if (!ReadVideoFormat()) return false;

    PROPVARIANT duration;
    PropVariantInit(&duration);
    if (SUCCEEDED(reader_->GetPresentationAttribute(
            static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION,
            &duration)) &&
        duration.vt == VT_UI8) {
      duration_ = static_cast<LONGLONG>(duration.uhVal.QuadPart);
    }
    PropVariantClear(&duration);
    return true;
  }

  // The decoded frame's size, picture area and row layout (again after the
  // decoder changes them mid-stream).
  bool ReadVideoFormat() {
    ComPtr<IMFMediaType> current;
    HRESULT hr = reader_->GetCurrentMediaType(video_stream_, &current);
    UINT32 width = 0;
    UINT32 height = 0;
    if (SUCCEEDED(hr)) hr = MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, &width, &height);
    if (FAILED(hr) || width == 0 || height == 0 || width > 16384 || height > 16384) {
      return Fail("video", "The size of this video is unknown.");
    }
    input_width_ = width;
    input_height_ = height;
    picture_ = PictureArea(current.Get(), width, height);
    // RGB rows run top-down unless the type says otherwise (a negative
    // stride means bottom-up).
    UINT32 stride = 0;
    default_stride_ = SUCCEEDED(current->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride))
                          ? static_cast<LONG>(stride)
                          : static_cast<LONG>(width * 4);
    frame_bitmap_.Reset();
    UpdateTransform();
    return true;
  }

  // 16-bit PCM at 44.1 or 48 kHz, mono or stereo: what the AAC encoder takes.
  bool ConfigureAudio() {
    if (audio_stream_ == kNoStream) return true;
    std::string error;
    if (!SelectPcmAudio(reader_.Get(), audio_stream_, &audio_type_, &audio_rate_, &audio_channels_, &error)) {
      audio_type_.Reset();
      return Fail("audio", error);
    }
    return true;
  }

  // The output frame (a WIC bitmap Direct2D draws on) and the overlay.
  bool PrepareCanvas() {
    const UINT width = static_cast<UINT>(request_.frame_width);
    const UINT height = static_cast<UINT>(request_.frame_height);
    HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                  CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic_));
    if (SUCCEEDED(hr)) {
      hr = wic_->CreateBitmap(width, height, GUID_WICPixelFormat32bppPBGRA,
                              WICBitmapCacheOnLoad, &canvas_);
    }
    if (SUCCEEDED(hr)) hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, d2d_.GetAddressOf());
    if (SUCCEEDED(hr)) {
      const D2D1_RENDER_TARGET_PROPERTIES properties = D2D1::RenderTargetProperties(
          D2D1_RENDER_TARGET_TYPE_SOFTWARE,
          D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED));
      hr = d2d_->CreateWicBitmapRenderTarget(canvas_.Get(), properties, &target_);
    }
    if (FAILED(hr)) return Fail("compose", WithCode("Windows could not prepare the drawing surface.", hr));

    const uint32_t rgb = request_.background_rgb;
    background_ = D2D1::ColorF(static_cast<FLOAT>((rgb >> 16) & 0xFF) / 255.0f,
                               static_cast<FLOAT>((rgb >> 8) & 0xFF) / 255.0f,
                               static_cast<FLOAT>(rgb & 0xFF) / 255.0f, 1.0f);
    // A transcode draws nothing on top.
    if (request_.overlay_png.empty()) return true;

    ComPtr<IWICStream> stream;
    ComPtr<IWICBitmapDecoder> decoder;
    ComPtr<IWICBitmapFrameDecode> frame;
    ComPtr<IWICFormatConverter> converter;
    hr = wic_->CreateStream(&stream);
    if (SUCCEEDED(hr)) {
      hr = stream->InitializeFromMemory(const_cast<BYTE*>(request_.overlay_png.data()),
                                        static_cast<DWORD>(request_.overlay_png.size()));
    }
    if (SUCCEEDED(hr)) {
      hr = wic_->CreateDecoderFromStream(stream.Get(), nullptr,
                                         WICDecodeMetadataCacheOnLoad, &decoder);
    }
    if (SUCCEEDED(hr)) hr = decoder->GetFrame(0, &frame);
    if (SUCCEEDED(hr)) hr = wic_->CreateFormatConverter(&converter);
    if (SUCCEEDED(hr)) {
      hr = converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppPBGRA,
                                 WICBitmapDitherTypeNone, nullptr, 0.0,
                                 WICBitmapPaletteTypeMedianCut);
    }
    if (SUCCEEDED(hr)) hr = target_->CreateBitmapFromWicBitmap(converter.Get(), nullptr, &overlay_);
    if (FAILED(hr)) return Fail("compose", WithCode("The caption image could not be read.", hr));
    return true;
  }

  // The requested bitrate, else about 0.12 bits per pixel per frame: 7.5
  // Mbit/s for 1080x1920 at 30 frames per second, within what TikTok and
  // Instagram keep.
  UINT32 VideoBitrate() const {
    if (request_.video_bitrate > 0) return request_.video_bitrate;
    const double rate = std::min(60.0, static_cast<double>(frame_rate_numerator_) /
                                           static_cast<double>(frame_rate_denominator_));
    const double bits = static_cast<double>(request_.frame_width) *
                        static_cast<double>(request_.frame_height) * rate * 0.12;
    return static_cast<UINT32>(std::clamp(bits, 2000000.0, 20000000.0));
  }

  bool OpenOutput() {
    const UINT32 width = static_cast<UINT32>(request_.frame_width);
    const UINT32 height = static_cast<UINT32>(request_.frame_height);
    DeleteFileW(request_.output_path.c_str());
    ComPtr<IMFAttributes> attributes;
    HRESULT hr = MFCreateAttributes(&attributes, 1);
    if (SUCCEEDED(hr)) hr = attributes->SetGUID(MF_TRANSCODE_CONTAINERTYPE, MFTranscodeContainerType_MPEG4);
    // Throttling stays on: WriteSample waits while the encoder is behind,
    // so decoded frames (8 MB each at 1080x1920) never pile up in memory.
    // MF_MPEG4SINK_MOOV_BEFORE_MDAT is left out: on Windows 10 it fails with
    // a write-only file and writes broken chunk offsets with a read-write one.
    if (SUCCEEDED(hr)) {
      hr = MFCreateSinkWriterFromURL(request_.output_path.c_str(), nullptr,
                                     attributes.Get(), &writer_);
    }
    if (FAILED(hr)) return Fail("compose", WithCode("NEFORUM could not create the new video file.", hr));

    ComPtr<IMFMediaType> h264;
    hr = CreateH264Type(width, height, frame_rate_numerator_, frame_rate_denominator_,
                        VideoBitrate(), &h264);
    if (SUCCEEDED(hr)) hr = writer_->AddStream(h264.Get(), &sink_video_);

    // The frames Direct2D draws: top-down BGRX rows.
    ComPtr<IMFMediaType> rgb;
    if (SUCCEEDED(hr)) hr = CreateRgbInputType(width, height, frame_rate_numerator_, frame_rate_denominator_, &rgb);
    // A requested bitrate (a copy made for a size limit) is held constant.
    ComPtr<IMFAttributes> parameters;
    if (SUCCEEDED(hr) && request_.video_bitrate > 0) {
      hr = ConstantBitrateParameters(request_.video_bitrate, &parameters);
    }
    if (SUCCEEDED(hr)) hr = writer_->SetInputMediaType(sink_video_, rgb.Get(), parameters.Get());
    if (FAILED(hr)) {
      return Fail("compose", WithCode("Windows has no H.264 encoder for this frame size.", hr));
    }

    if (audio_type_) {
      ComPtr<IMFMediaType> aac;
      hr = CreateAacType(audio_rate_, audio_channels_,
                         AacBytesPerSecond(request_.audio_bitrate, audio_channels_), &aac);
      if (SUCCEEDED(hr)) hr = writer_->AddStream(aac.Get(), &sink_audio_);
      if (SUCCEEDED(hr)) hr = writer_->SetInputMediaType(sink_audio_, audio_type_.Get(), nullptr);
      if (FAILED(hr)) return Fail("audio", WithCode("Windows could not encode the sound of this video.", hr));
    }

    hr = writer_->BeginWriting();
    if (FAILED(hr)) return Fail("compose", WithCode("Windows could not start the encoder.", hr));
    return true;
  }

  // Bitmap coordinates of the picture to output coordinates: centred on the
  // origin, turned clockwise by the rotation, scaled to the video rectangle
  // and moved to its centre.
  void UpdateTransform() {
    const FLOAT area_width = static_cast<FLOAT>(picture_.right - picture_.left);
    const FLOAT area_height = static_cast<FLOAT>(picture_.bottom - picture_.top);
    const bool quarter = rotation_ == 90 || rotation_ == 270;
    const FLOAT shown_width = quarter ? area_height : area_width;
    const FLOAT shown_height = quarter ? area_width : area_height;
    const FLOAT width = static_cast<FLOAT>(request_.video_width);
    const FLOAT height = static_cast<FLOAT>(request_.video_height);
    transform_ = D2D1::Matrix3x2F::Translation(-area_width / 2.0f, -area_height / 2.0f) *
                 D2D1::Matrix3x2F::Rotation(static_cast<FLOAT>(rotation_)) *
                 D2D1::Matrix3x2F::Scale(width / shown_width, height / shown_height) *
                 D2D1::Matrix3x2F::Translation(static_cast<FLOAT>(request_.video_left) + width / 2.0f,
                                               static_cast<FLOAT>(request_.video_top) + height / 2.0f);
  }

  // Copies decoded rows (|pitch| bytes apart, negative when bottom-up) into
  // the frame bitmap.
  bool CopyFrame(const BYTE* top_row, LONG pitch) {
    const UINT32 row = input_width_ * 4;
    if (pitch >= static_cast<LONG>(row)) {
      return SUCCEEDED(frame_bitmap_->CopyFromMemory(nullptr, top_row, static_cast<UINT32>(pitch)));
    }
    if (pitch <= -static_cast<LONG>(row)) {
      rows_.resize(static_cast<size_t>(row) * input_height_);
      for (UINT32 y = 0; y < input_height_; y++) {
        memcpy(rows_.data() + static_cast<size_t>(y) * row,
               top_row + static_cast<ptrdiff_t>(y) * pitch, row);
      }
      return SUCCEEDED(frame_bitmap_->CopyFromMemory(nullptr, rows_.data(), row));
    }
    return false;
  }

  bool WriteVideo(IMFSample* sample, LONGLONG time) {
    LONGLONG duration = 0;
    if (FAILED(sample->GetSampleDuration(&duration)) || duration <= 0) {
      duration = kTicksPerSecond * frame_rate_denominator_ / frame_rate_numerator_;
    }
    ComPtr<IMFMediaBuffer> buffer;
    HRESULT hr = sample->ConvertToContiguousBuffer(&buffer);
    if (FAILED(hr)) return Fail("compose", WithCode("A frame of this video could not be read.", hr));
    if (!frame_bitmap_) {
      hr = target_->CreateBitmap(
          D2D1::SizeU(input_width_, input_height_),
          D2D1::BitmapProperties(D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_IGNORE)),
          &frame_bitmap_);
      if (FAILED(hr)) return Fail("compose", WithCode("Windows could not prepare a video frame.", hr));
    }

    bool copied = false;
    ComPtr<IMF2DBuffer> buffer2d;
    if (SUCCEEDED(buffer.As(&buffer2d))) {
      BYTE* top_row = nullptr;
      LONG pitch = 0;
      if (SUCCEEDED(buffer2d->Lock2D(&top_row, &pitch))) {
        copied = CopyFrame(top_row, pitch);
        buffer2d->Unlock2D();
      }
    }
    if (!copied) {
      BYTE* data = nullptr;
      DWORD length = 0;
      if (SUCCEEDED(buffer->Lock(&data, nullptr, &length))) {
        const LONG pitch = default_stride_;
        const size_t needed = static_cast<size_t>(pitch < 0 ? -pitch : pitch) * input_height_;
        if (length >= needed) {
          const BYTE* top_row =
              pitch < 0 ? data + static_cast<size_t>(-pitch) * (input_height_ - 1) : data;
          copied = CopyFrame(top_row, pitch);
        }
        buffer->Unlock();
      }
    }
    if (!copied) return Fail("compose", "A frame of this video could not be read.");

    const FLOAT frame_width = static_cast<FLOAT>(request_.frame_width);
    const FLOAT frame_height = static_cast<FLOAT>(request_.frame_height);
    const D2D1_RECT_F picture = D2D1::RectF(
        static_cast<FLOAT>(picture_.left), static_cast<FLOAT>(picture_.top),
        static_cast<FLOAT>(picture_.right), static_cast<FLOAT>(picture_.bottom));
    target_->BeginDraw();
    target_->SetTransform(D2D1::Matrix3x2F::Identity());
    target_->Clear(background_);
    target_->SetTransform(transform_);
    target_->DrawBitmap(frame_bitmap_.Get(),
                        D2D1::RectF(0.0f, 0.0f, picture.right - picture.left, picture.bottom - picture.top),
                        1.0f, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, &picture);
    target_->SetTransform(D2D1::Matrix3x2F::Identity());
    if (overlay_) {
      target_->DrawBitmap(overlay_.Get(), D2D1::RectF(0.0f, 0.0f, frame_width, frame_height),
                          1.0f, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
    }
    hr = target_->EndDraw();
    if (FAILED(hr)) return Fail("compose", WithCode("Windows could not draw a video frame.", hr));

    const UINT width = static_cast<UINT>(request_.frame_width);
    const UINT height = static_cast<UINT>(request_.frame_height);
    const DWORD out_stride = width * 4;
    const DWORD out_size = out_stride * height;
    ComPtr<IMFMediaBuffer> out;
    hr = MFCreateMemoryBuffer(out_size, &out);
    if (SUCCEEDED(hr)) {
      const WICRect all = {0, 0, static_cast<INT>(width), static_cast<INT>(height)};
      ComPtr<IWICBitmapLock> lock;
      UINT stride = 0;
      UINT size = 0;
      BYTE* pixels = nullptr;
      BYTE* destination = nullptr;
      hr = canvas_->Lock(&all, WICBitmapLockRead, &lock);
      if (SUCCEEDED(hr)) hr = lock->GetStride(&stride);
      if (SUCCEEDED(hr)) hr = lock->GetDataPointer(&size, &pixels);
      if (SUCCEEDED(hr)) hr = out->Lock(&destination, nullptr, nullptr);
      if (SUCCEEDED(hr)) {
        hr = MFCopyImage(destination, static_cast<LONG>(out_stride), pixels,
                         static_cast<LONG>(stride), out_stride, height);
        out->Unlock();
      }
      if (SUCCEEDED(hr)) hr = out->SetCurrentLength(out_size);
    }
    ComPtr<IMFSample> frame;
    if (SUCCEEDED(hr)) hr = MFCreateSample(&frame);
    if (SUCCEEDED(hr)) hr = frame->AddBuffer(out.Get());
    if (SUCCEEDED(hr)) hr = frame->SetSampleTime(time);
    if (SUCCEEDED(hr)) hr = frame->SetSampleDuration(duration);
    if (SUCCEEDED(hr)) hr = writer_->WriteSample(sink_video_, frame.Get());
    if (FAILED(hr)) return Fail("compose", WithCode("Windows could not encode a video frame.", hr));
    Report(time);
    return true;
  }

  void Report(LONGLONG time) {
    if (!progress_ || duration_ <= 0) return;
    const double value = std::clamp(static_cast<double>(time) / static_cast<double>(duration_), 0.0, 0.99);
    const auto now = std::chrono::steady_clock::now();
    if (value - last_progress_ < 0.01 && now - last_report_ < std::chrono::milliseconds(500)) return;
    last_progress_ = value;
    last_report_ = now;
    progress_(value);
  }

  // Reads every sample in file order: video frames are drawn and encoded,
  // sound goes to the AAC encoder as it is.
  bool Process() {
    bool video_done = false;
    bool audio_done = !audio_type_;
    while (!video_done || !audio_done) {
      if (cancelled_) return Fail("cancelled", "The video was not finished because NEFORUM closed.");
      DWORD stream = 0;
      DWORD flags = 0;
      LONGLONG time = 0;
      ComPtr<IMFSample> sample;
      HRESULT hr = reader_->ReadSample(static_cast<DWORD>(MF_SOURCE_READER_ANY_STREAM), 0, &stream,
                                       &flags, &time, &sample);
      if (FAILED(hr) || (flags & MF_SOURCE_READERF_ERROR)) {
        return Fail("compose", WithCode("This video could not be read to the end.", hr));
      }
      const bool is_video = stream == video_stream_;
      if (!is_video && stream != audio_stream_) continue;
      if (is_video && (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) && !ReadVideoFormat()) {
        return false;
      }
      if (flags & MF_SOURCE_READERF_STREAMTICK) {
        writer_->SendStreamTick(is_video ? sink_video_ : sink_audio_, time);
      }
      // Samples before the start of the timeline (edit lists) are not shown.
      if (sample && time >= 0) {
        if (is_video) {
          if (!WriteVideo(sample.Get(), time)) return false;
        } else {
          hr = writer_->WriteSample(sink_audio_, sample.Get());
          if (FAILED(hr)) return Fail("audio", WithCode("Windows could not encode the sound of this video.", hr));
        }
      }
      if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
        (is_video ? video_done : audio_done) = true;
        reader_->SetStreamSelection(stream, FALSE);
      }
    }
    const HRESULT hr = writer_->Finalize();
    if (FAILED(hr)) return Fail("compose", WithCode("Windows could not finish the new video.", hr));
    if (progress_) progress_(1.0);
    return true;
  }

  const VideoCompositionRequest& request_;
  const std::function<void(double)>& progress_;
  const std::atomic<bool>& cancelled_;
  std::string code_ = "compose";
  std::string message_;

  ComPtr<IMFSourceReader> reader_;
  ComPtr<IMFSinkWriter> writer_;
  DWORD video_stream_ = kNoStream;
  DWORD audio_stream_ = kNoStream;
  DWORD sink_video_ = 0;
  DWORD sink_audio_ = 0;
  ComPtr<IMFMediaType> audio_type_;
  UINT32 audio_rate_ = 0;
  UINT32 audio_channels_ = 0;

  int rotation_ = 0;
  UINT32 frame_rate_numerator_ = 30;
  UINT32 frame_rate_denominator_ = 1;
  LONGLONG duration_ = 0;
  UINT32 input_width_ = 0;
  UINT32 input_height_ = 0;
  RECT picture_ = {};
  LONG default_stride_ = 0;
  std::vector<BYTE> rows_;

  ComPtr<IWICImagingFactory> wic_;
  ComPtr<IWICBitmap> canvas_;
  ComPtr<ID2D1Factory> d2d_;
  ComPtr<ID2D1RenderTarget> target_;
  ComPtr<ID2D1Bitmap> overlay_;
  ComPtr<ID2D1Bitmap> frame_bitmap_;
  D2D1_COLOR_F background_ = {};
  D2D1_MATRIX_3X2_F transform_ = D2D1::Matrix3x2F::Identity();

  double last_progress_ = 0.0;
  std::chrono::steady_clock::time_point last_report_;
};

// Progress of a run through a file of |duration| ticks, at most every 1% or
// half a second, never 1 before the file is finished.
class ProgressReporter {
 public:
  explicit ProgressReporter(const std::function<void(double)>& progress) : progress_(progress) {}

  void Report(LONGLONG time, LONGLONG duration) {
    if (!progress_ || duration <= 0) return;
    const double value = std::clamp(static_cast<double>(time) / static_cast<double>(duration), 0.0, 0.99);
    const auto now = std::chrono::steady_clock::now();
    if (value - last_progress_ < 0.01 && now - last_report_ < std::chrono::milliseconds(500)) return;
    last_progress_ = value;
    last_report_ = now;
    progress_(value);
  }

  void Done() {
    if (progress_) progress_(1.0);
  }

 private:
  const std::function<void(double)>& progress_;
  double last_progress_ = 0.0;
  std::chrono::steady_clock::time_point last_report_;
};

// The first audio stream of the file at |path|, alone, decoded to PCM
// (SelectPcmAudio).
struct PcmSource {
  ComPtr<IMFSourceReader> reader;
  DWORD stream = kNoStream;
  ComPtr<IMFMediaType> type;
  UINT32 rate = 0;
  UINT32 channels = 0;
  LONGLONG duration = 0;
};

bool OpenPcmSource(const std::wstring& path, PcmSource* source, std::string* error) {
  HRESULT hr = MFCreateSourceReaderFromURL(path.c_str(), nullptr, &source->reader);
  if (FAILED(hr)) {
    *error = WithCode("NEFORUM could not open this sound file.", hr);
    return false;
  }
  source->stream = FindStreams(source->reader.Get()).audio;
  if (source->stream == kNoStream) {
    *error = "This file has no sound.";
    return false;
  }
  source->reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
  source->reader->SetStreamSelection(source->stream, TRUE);
  if (!SelectPcmAudio(source->reader.Get(), source->stream, &source->type, &source->rate,
                      &source->channels, error)) {
    return false;
  }
  source->duration = DurationOf(source->reader.Get());
  return true;
}

// The MP3 encoder's own output type for |pcm| closest to |bits_per_second|
// without going over it (else its lowest): the encoder lists the rates it
// takes for this sample rate and channel count.
bool FindMp3Type(IMFMediaType* pcm, uint32_t bits_per_second, ComPtr<IMFMediaType>* out) {
  // Only the output is matched: the MP3 encoder registers no input types.
  MFT_REGISTER_TYPE_INFO output = {MFMediaType_Audio, MFAudioFormat_MP3};
  IMFActivate** activates = nullptr;
  UINT32 count = 0;
  if (FAILED(MFTEnumEx(MFT_CATEGORY_AUDIO_ENCODER,
                       MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_SORTANDFILTER,
                       nullptr, &output, &activates, &count))) {
    return false;
  }
  const UINT32 rate = MFGetAttributeUINT32(pcm, MF_MT_AUDIO_SAMPLES_PER_SECOND, 0);
  const UINT32 channels = MFGetAttributeUINT32(pcm, MF_MT_AUDIO_NUM_CHANNELS, 0);
  const UINT32 wanted = bits_per_second / 8;
  ComPtr<IMFMediaType> best;
  UINT32 best_bytes = 0;
  for (UINT32 i = 0; i < count && !best; i++) {
    ComPtr<IMFTransform> encoder;
    if (SUCCEEDED(activates[i]->ActivateObject(IID_PPV_ARGS(&encoder))) &&
        SUCCEEDED(encoder->SetInputType(0, pcm, 0))) {
      for (DWORD t = 0;; t++) {
        ComPtr<IMFMediaType> type;
        if (FAILED(encoder->GetOutputAvailableType(0, t, &type))) break;
        GUID subtype = GUID_NULL;
        if (FAILED(type->GetGUID(MF_MT_SUBTYPE, &subtype)) || subtype != MFAudioFormat_MP3 ||
            MFGetAttributeUINT32(type.Get(), MF_MT_AUDIO_SAMPLES_PER_SECOND, 0) != rate ||
            MFGetAttributeUINT32(type.Get(), MF_MT_AUDIO_NUM_CHANNELS, 0) != channels) {
          continue;
        }
        const UINT32 bytes = MFGetAttributeUINT32(type.Get(), MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 0);
        if (bytes == 0) continue;
        const bool better = !best || (bytes <= wanted && (best_bytes > wanted || bytes > best_bytes)) ||
                            (bytes > wanted && best_bytes > wanted && bytes < best_bytes);
        if (better) {
          best = type;
          best_bytes = bytes;
        }
      }
      // The sink writer makes its own encoder from the type.
      if (best) {
        ComPtr<IMFMediaType> copy;
        if (SUCCEEDED(MFCreateMediaType(&copy)) && SUCCEEDED(best->CopyAllItems(copy.Get()))) {
          *out = copy;
        } else {
          best.Reset();
        }
      }
    }
    activates[i]->ShutdownObject();
  }
  for (UINT32 i = 0; i < count; i++) activates[i]->Release();
  CoTaskMemFree(activates);
  return out->Get() != nullptr;
}

// An MP3 type built by hand, for when the encoder lists none: MPEG-1 layer 3
// at the largest of its rates (64 to 320 kbit/s) not above |bits_per_second|.
HRESULT CreateMp3Type(UINT32 rate, UINT32 channels, uint32_t bits_per_second, ComPtr<IMFMediaType>* type) {
  static constexpr UINT32 kBytesPerSecond[] = {8000, 10000, 12000, 14000, 16000, 20000, 24000, 28000, 32000, 40000};
  UINT32 bytes = kBytesPerSecond[0];
  for (const UINT32 option : kBytesPerSecond) {
    if (option <= bits_per_second / 8) bytes = option;
  }
  HRESULT hr = MFCreateMediaType(type->ReleaseAndGetAddressOf());
  IMFMediaType* mp3 = type->Get();
  if (SUCCEEDED(hr)) hr = mp3->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  if (SUCCEEDED(hr)) hr = mp3->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_MP3);
  if (SUCCEEDED(hr)) hr = mp3->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, rate);
  if (SUCCEEDED(hr)) hr = mp3->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, channels);
  if (SUCCEEDED(hr)) hr = mp3->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, bytes);
  if (SUCCEEDED(hr)) hr = mp3->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 1);
  return hr;
}

// Writes a still picture as an H.264 video at 30 frames per second for as
// long as a sound file lasts, with that sound as AAC: decoded sound goes to
// the encoder as it is, and before each piece of it the frames that start
// before it ends, so the two stay interleaved.
class StillVideoWriter {
 public:
  StillVideoWriter(const StillVideoRequest& request, const std::function<void(double)>& progress,
                   const std::atomic<bool>& cancelled)
      : request_(request), cancelled_(cancelled), reporter_(progress) {}
  StillVideoWriter(const StillVideoWriter&) = delete;
  StillVideoWriter& operator=(const StillVideoWriter&) = delete;

  bool Run(std::string* code, std::string* message) {
    const bool ok = OpenAudio() && PreparePicture() && OpenOutput() && Process();
    if (!ok) {
      *code = code_;
      *message = message_;
    }
    return ok;
  }

 private:
  // Platforms take 30 frames per second everywhere; a frame that never
  // changes costs almost nothing after the first.
  static constexpr UINT32 kFrameRate = 30;
  // A key frame every 10 seconds.
  static constexpr UINT32 kKeyFrameInterval = 300;

  static LONGLONG FrameTime(int64_t frame) { return frame * kTicksPerSecond / kFrameRate; }

  bool Fail(const char* code, std::string message) {
    code_ = code;
    message_ = std::move(message);
    return false;
  }

  bool OpenAudio() {
    std::string error;
    if (!OpenPcmSource(request_.audio_path, &audio_, &error)) return Fail("audio", error);
    return true;
  }

  bool PreparePicture() {
    const UINT width = static_cast<UINT>(request_.frame_width);
    const UINT height = static_cast<UINT>(request_.frame_height);
    const DWORD size = width * height * 4;
    ComPtr<IWICImagingFactory> wic;
    HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic));
    if (SUCCEEDED(hr)) hr = MFCreateMemoryBuffer(size, &picture_);
    BYTE* pixels = nullptr;
    if (SUCCEEDED(hr)) hr = picture_->Lock(&pixels, nullptr, nullptr);
    if (SUCCEEDED(hr)) {
      hr = DecodePicture(wic.Get(), request_.image_png, width, height, pixels);
      picture_->Unlock();
    }
    if (SUCCEEDED(hr)) hr = picture_->SetCurrentLength(size);
    if (FAILED(hr)) return Fail("audioVideo", WithCode("The picture could not be read.", hr));
    return true;
  }

  bool OpenOutput() {
    const UINT32 width = static_cast<UINT32>(request_.frame_width);
    const UINT32 height = static_cast<UINT32>(request_.frame_height);
    DeleteFileW(request_.output_path.c_str());
    ComPtr<IMFAttributes> attributes;
    HRESULT hr = MFCreateAttributes(&attributes, 1);
    if (SUCCEEDED(hr)) hr = attributes->SetGUID(MF_TRANSCODE_CONTAINERTYPE, MFTranscodeContainerType_MPEG4);
    if (SUCCEEDED(hr)) hr = MFCreateSinkWriterFromURL(request_.output_path.c_str(), nullptr, attributes.Get(), &writer_);
    if (FAILED(hr)) return Fail("audioVideo", WithCode("NEFORUM could not create the new video file.", hr));

    ComPtr<IMFMediaType> h264;
    hr = CreateH264Type(width, height, kFrameRate, 1, 2000000, &h264);
    if (SUCCEEDED(hr)) hr = writer_->AddStream(h264.Get(), &sink_video_);
    ComPtr<IMFMediaType> rgb;
    if (SUCCEEDED(hr)) hr = CreateRgbInputType(width, height, kFrameRate, 1, &rgb);
    // Constant quality: the repeated frames shrink to almost nothing, where
    // a bitrate would be spent on them anyway.
    ComPtr<IMFAttributes> parameters;
    if (SUCCEEDED(hr)) hr = MFCreateAttributes(&parameters, 3);
    if (SUCCEEDED(hr)) hr = parameters->SetUINT32(CODECAPI_AVEncCommonRateControlMode, eAVEncCommonRateControlMode_Quality);
    if (SUCCEEDED(hr)) hr = parameters->SetUINT32(CODECAPI_AVEncCommonQuality, 70);
    if (SUCCEEDED(hr)) hr = parameters->SetUINT32(CODECAPI_AVEncMPVGOPSize, kKeyFrameInterval);
    if (SUCCEEDED(hr)) hr = writer_->SetInputMediaType(sink_video_, rgb.Get(), parameters.Get());
    if (FAILED(hr)) return Fail("audioVideo", WithCode("Windows has no H.264 encoder for this frame size.", hr));

    ComPtr<IMFMediaType> aac;
    hr = CreateAacType(audio_.rate, audio_.channels, AacBytesPerSecond(request_.audio_bitrate, audio_.channels), &aac);
    if (SUCCEEDED(hr)) hr = writer_->AddStream(aac.Get(), &sink_audio_);
    if (SUCCEEDED(hr)) hr = writer_->SetInputMediaType(sink_audio_, audio_.type.Get(), nullptr);
    if (FAILED(hr)) return Fail("audio", WithCode("Windows could not encode this sound.", hr));

    hr = writer_->BeginWriting();
    if (FAILED(hr)) return Fail("audioVideo", WithCode("Windows could not start the encoder.", hr));
    return true;
  }

  // Every frame that starts before |end|.
  bool WriteFramesBefore(LONGLONG end) {
    while (FrameTime(next_frame_) < end) {
      if (cancelled_) return Fail("cancelled", "The video was not finished because NEFORUM closed.");
      const LONGLONG time = FrameTime(next_frame_);
      ComPtr<IMFSample> frame;
      HRESULT hr = MFCreateSample(&frame);
      // Every frame shares the picture's buffer: nothing writes to it again.
      if (SUCCEEDED(hr)) hr = frame->AddBuffer(picture_.Get());
      if (SUCCEEDED(hr)) hr = frame->SetSampleTime(time);
      if (SUCCEEDED(hr)) hr = frame->SetSampleDuration(FrameTime(next_frame_ + 1) - time);
      if (SUCCEEDED(hr)) hr = writer_->WriteSample(sink_video_, frame.Get());
      if (FAILED(hr)) return Fail("audioVideo", WithCode("Windows could not encode a video frame.", hr));
      next_frame_++;
    }
    return true;
  }

  bool Process() {
    LONGLONG end = 0;
    for (;;) {
      if (cancelled_) return Fail("cancelled", "The video was not finished because NEFORUM closed.");
      DWORD flags = 0;
      LONGLONG time = 0;
      ComPtr<IMFSample> sample;
      HRESULT hr = audio_.reader->ReadSample(audio_.stream, 0, nullptr, &flags, &time, &sample);
      if (FAILED(hr) || (flags & MF_SOURCE_READERF_ERROR)) {
        return Fail("audio", WithCode("This sound file could not be read to the end.", hr));
      }
      if (sample && time >= 0) {
        LONGLONG duration = 0;
        if (FAILED(sample->GetSampleDuration(&duration)) || duration < 0) duration = 0;
        if (!WriteFramesBefore(time + duration)) return false;
        hr = writer_->WriteSample(sink_audio_, sample.Get());
        if (FAILED(hr)) return Fail("audio", WithCode("Windows could not encode this sound.", hr));
        end = std::max(end, time + duration);
        reporter_.Report(time, audio_.duration);
      }
      if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
    }
    if (end <= 0) return Fail("audio", "This sound file is empty.");
    if (!WriteFramesBefore(end)) return false;
    const HRESULT hr = writer_->Finalize();
    if (FAILED(hr)) return Fail("audioVideo", WithCode("Windows could not finish the new video.", hr));
    reporter_.Done();
    return true;
  }

  const StillVideoRequest& request_;
  const std::atomic<bool>& cancelled_;
  ProgressReporter reporter_;
  std::string code_ = "audioVideo";
  std::string message_;

  PcmSource audio_;
  ComPtr<IMFMediaBuffer> picture_;
  ComPtr<IMFSinkWriter> writer_;
  DWORD sink_video_ = 0;
  DWORD sink_audio_ = 0;
  int64_t next_frame_ = 0;
};

// Converts a sound file to MP3 (the system's MP3 encoder) or to AAC in an
// MPEG-4 file (.m4a).
class AudioTranscoder {
 public:
  AudioTranscoder(const AudioTranscodeRequest& request, const std::function<void(double)>& progress,
                  const std::atomic<bool>& cancelled)
      : request_(request), cancelled_(cancelled), reporter_(progress) {}
  AudioTranscoder(const AudioTranscoder&) = delete;
  AudioTranscoder& operator=(const AudioTranscoder&) = delete;

  bool Run(std::string* code, std::string* message) {
    const bool ok = OpenInput() && OpenOutput() && Process();
    if (!ok) {
      *code = code_;
      *message = message_;
    }
    return ok;
  }

 private:
  bool Fail(const char* code, std::string message) {
    code_ = code;
    message_ = std::move(message);
    return false;
  }

  bool OpenInput() {
    std::string error;
    if (!OpenPcmSource(request_.input_path, &audio_, &error)) return Fail("audio", error);
    return true;
  }

  bool OpenOutput() {
    const bool mp3 = request_.format == "mp3";
    ComPtr<IMFMediaType> encoded;
    if (mp3) {
      if (!FindMp3Type(audio_.type.Get(), request_.bitrate, &encoded) &&
          FAILED(CreateMp3Type(audio_.rate, audio_.channels, request_.bitrate, &encoded))) {
        return Fail("unsupported", "Windows has no MP3 encoder for this sound on this PC.");
      }
    } else if (FAILED(CreateAacType(audio_.rate, audio_.channels,
                                    AacBytesPerSecond(request_.bitrate, audio_.channels), &encoded))) {
      return Fail("transcodeAudio", "Windows could not prepare the AAC encoder.");
    }

    DeleteFileW(request_.output_path.c_str());
    ComPtr<IMFAttributes> attributes;
    HRESULT hr = MFCreateAttributes(&attributes, 1);
    if (SUCCEEDED(hr)) {
      hr = attributes->SetGUID(MF_TRANSCODE_CONTAINERTYPE,
                               mp3 ? MFTranscodeContainerType_MP3 : MFTranscodeContainerType_MPEG4);
    }
    if (SUCCEEDED(hr)) hr = MFCreateSinkWriterFromURL(request_.output_path.c_str(), nullptr, attributes.Get(), &writer_);
    if (FAILED(hr)) return Fail("transcodeAudio", WithCode("NEFORUM could not create the new sound file.", hr));
    hr = writer_->AddStream(encoded.Get(), &sink_);
    if (SUCCEEDED(hr)) hr = writer_->SetInputMediaType(sink_, audio_.type.Get(), nullptr);
    if (FAILED(hr)) {
      return Fail("transcodeAudio", WithCode(mp3 ? "Windows could not encode this sound as MP3." : "Windows could not encode this sound.", hr));
    }
    hr = writer_->BeginWriting();
    if (FAILED(hr)) return Fail("transcodeAudio", WithCode("Windows could not start the encoder.", hr));
    return true;
  }

  bool Process() {
    LONGLONG end = 0;
    for (;;) {
      if (cancelled_) return Fail("cancelled", "The sound file was not finished because NEFORUM closed.");
      DWORD flags = 0;
      LONGLONG time = 0;
      ComPtr<IMFSample> sample;
      HRESULT hr = audio_.reader->ReadSample(audio_.stream, 0, nullptr, &flags, &time, &sample);
      if (FAILED(hr) || (flags & MF_SOURCE_READERF_ERROR)) {
        return Fail("audio", WithCode("This sound file could not be read to the end.", hr));
      }
      if (flags & MF_SOURCE_READERF_STREAMTICK) writer_->SendStreamTick(sink_, time);
      if (sample && time >= 0) {
        hr = writer_->WriteSample(sink_, sample.Get());
        if (FAILED(hr)) return Fail("transcodeAudio", WithCode("Windows could not encode this sound.", hr));
        LONGLONG duration = 0;
        if (SUCCEEDED(sample->GetSampleDuration(&duration)) && duration > 0) end = std::max(end, time + duration);
        reporter_.Report(time, audio_.duration);
      }
      if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
    }
    if (end <= 0) return Fail("audio", "This sound file is empty.");
    const HRESULT hr = writer_->Finalize();
    if (FAILED(hr)) return Fail("transcodeAudio", WithCode("Windows could not finish the new sound file.", hr));
    reporter_.Done();
    return true;
  }

  const AudioTranscodeRequest& request_;
  const std::atomic<bool>& cancelled_;
  ProgressReporter reporter_;
  std::string code_ = "transcodeAudio";
  std::string message_;

  PcmSource audio_;
  ComPtr<IMFSinkWriter> writer_;
  DWORD sink_ = 0;
};

// |source| encoded as a PNG.
HRESULT EncodePng(IWICImagingFactory* wic, IWICBitmapSource* source, std::vector<uint8_t>* png) {
  ComPtr<IStream> stream;
  ComPtr<IWICBitmapEncoder> encoder;
  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IWICFormatConverter> converter;
  HRESULT hr = CreateStreamOnHGlobal(nullptr, TRUE, &stream);
  if (SUCCEEDED(hr)) hr = wic->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
  if (SUCCEEDED(hr)) hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
  if (SUCCEEDED(hr)) hr = encoder->CreateNewFrame(&frame, nullptr);
  if (SUCCEEDED(hr)) hr = frame->Initialize(nullptr);
  UINT width = 0;
  UINT height = 0;
  if (SUCCEEDED(hr)) hr = source->GetSize(&width, &height);
  if (SUCCEEDED(hr)) hr = frame->SetSize(width, height);
  // Video has no alpha: 24-bit rows, or whatever the encoder settles on.
  WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
  if (SUCCEEDED(hr)) hr = frame->SetPixelFormat(&format);
  if (SUCCEEDED(hr)) hr = wic->CreateFormatConverter(&converter);
  if (SUCCEEDED(hr)) {
    hr = converter->Initialize(source, format, WICBitmapDitherTypeNone, nullptr, 0.0,
                               WICBitmapPaletteTypeMedianCut);
  }
  if (SUCCEEDED(hr)) hr = frame->WriteSource(converter.Get(), nullptr);
  if (SUCCEEDED(hr)) hr = frame->Commit();
  if (SUCCEEDED(hr)) hr = encoder->Commit();
  ULARGE_INTEGER end = {};
  if (SUCCEEDED(hr)) hr = stream->Seek(LARGE_INTEGER{}, STREAM_SEEK_CUR, &end);
  HGLOBAL memory = nullptr;
  if (SUCCEEDED(hr)) hr = GetHGlobalFromStream(stream.Get(), &memory);
  if (SUCCEEDED(hr)) {
    const void* bytes = GlobalLock(memory);
    if (bytes == nullptr) return E_FAIL;
    const auto* first = static_cast<const uint8_t*>(bytes);
    png->assign(first, first + static_cast<size_t>(end.QuadPart));
    GlobalUnlock(memory);
  }
  return hr;
}

const flutter::EncodableValue* Field(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

std::string StringField(const flutter::EncodableMap& map, const char* key) {
  const auto* value = Field(map, key);
  const auto* text = value ? std::get_if<std::string>(value) : nullptr;
  return text ? *text : std::string();
}

int64_t IntField(const flutter::EncodableMap& map, const char* key) {
  const auto* value = Field(map, key);
  if (!value) return 0;
  // The standard codec sends ints that fit in 32 bits as such.
  if (const auto* value32 = std::get_if<int32_t>(value)) return *value32;
  if (const auto* value64 = std::get_if<int64_t>(value)) return *value64;
  return 0;
}

std::vector<uint8_t> BytesField(const flutter::EncodableMap& map, const char* key) {
  const auto* value = Field(map, key);
  const auto* bytes = value ? std::get_if<std::vector<uint8_t>>(value) : nullptr;
  return bytes ? *bytes : std::vector<uint8_t>();
}

// A bitrate argument: bits per second from 0 to 4 Gbit/s.
uint32_t BitrateField(const flutter::EncodableMap& map, const char* key) {
  return static_cast<uint32_t>(std::clamp<int64_t>(IntField(map, key), 0, 0xFFFFFFFFLL));
}

}  // namespace

bool VideoCompositionSupported() {
  MediaFoundationScope scope;
  if (!scope.started()) return false;
  return EncoderAvailable(MFT_CATEGORY_VIDEO_ENCODER, MFMediaType_Video, MFVideoFormat_H264) &&
         EncoderAvailable(MFT_CATEGORY_AUDIO_ENCODER, MFMediaType_Audio, MFAudioFormat_AAC);
}

bool ProbeVideoFile(const std::wstring& path, VideoFileProbe* probe, std::string* error) {
  MediaFoundationScope scope;
  if (!scope.started()) {
    *error = "Windows Media Foundation is not available on this PC.";
    return false;
  }
  ComPtr<IMFSourceReader> reader;
  HRESULT hr = MFCreateSourceReaderFromURL(path.c_str(), nullptr, &reader);
  if (FAILED(hr)) {
    *error = WithCode("NEFORUM could not open this video.", hr);
    return false;
  }
  const StreamIndices streams = FindStreams(reader.Get());
  ComPtr<IMFMediaType> video;
  if (streams.video == kNoStream || FAILED(reader->GetNativeMediaType(streams.video, 0, &video))) {
    *error = "This file has no video.";
    return false;
  }
  UINT32 width = 0;
  UINT32 height = 0;
  if (FAILED(MFGetAttributeSize(video.Get(), MF_MT_FRAME_SIZE, &width, &height)) || width == 0 ||
      height == 0) {
    *error = "The size of this video is unknown.";
    return false;
  }
  const RECT area = PictureArea(video.Get(), width, height);
  probe->width = static_cast<int>(area.right - area.left);
  probe->height = static_cast<int>(area.bottom - area.top);
  probe->rotation = RotationOf(video.Get());
  PROPVARIANT duration;
  PropVariantInit(&duration);
  if (SUCCEEDED(reader->GetPresentationAttribute(static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE),
                                                 MF_PD_DURATION, &duration)) &&
      duration.vt == VT_UI8) {
    probe->duration_ms = static_cast<int64_t>(duration.uhVal.QuadPart / 10000);
  }
  PropVariantClear(&duration);
  probe->has_audio = streams.audio != kNoStream;
  return true;
}

bool ComposeVideoFile(const VideoCompositionRequest& request,
                      const std::function<void(double)>& progress,
                      const std::atomic<bool>& cancelled, std::string* error_code,
                      std::string* error) {
  const bool frame_ok = request.frame_width >= 16 && request.frame_height >= 16 &&
                        request.frame_width <= 4096 && request.frame_height <= 4096 &&
                        request.frame_width % 2 == 0 && request.frame_height % 2 == 0;
  const bool video_ok = request.video_width > 0 && request.video_height > 0 &&
                        request.video_left >= 0 && request.video_top >= 0 &&
                        request.video_left + request.video_width <= request.frame_width &&
                        request.video_top + request.video_height <= request.frame_height;
  if (!frame_ok || !video_ok || request.input_path.empty() || request.output_path.empty() ||
      request.input_path == request.output_path) {
    *error_code = "args";
    *error = "The video request is not complete.";
    return false;
  }
  bool ok = false;
  {
    MediaFoundationScope scope;
    if (!scope.started()) {
      *error_code = "unsupported";
      *error = "Windows Media Foundation is not available on this PC.";
      return false;
    }
    Composer composer(request, progress, cancelled);
    ok = composer.Run(error_code, error);
  }
  // The writer has closed the file: a half-written one is removed.
  if (!ok) DeleteFileW(request.output_path.c_str());
  return ok;
}

bool ReadVideoFrame(const std::wstring& path, int64_t position_ms, int max_side,
                    VideoFrameImage* frame, std::string* error) {
  MediaFoundationScope scope;
  if (!scope.started()) {
    *error = "Windows Media Foundation is not available on this PC.";
    return false;
  }
  ComPtr<IMFAttributes> attributes;
  ComPtr<IMFSourceReader> reader;
  HRESULT hr = MFCreateAttributes(&attributes, 1);
  if (SUCCEEDED(hr)) hr = attributes->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
  if (SUCCEEDED(hr)) hr = MFCreateSourceReaderFromURL(path.c_str(), attributes.Get(), &reader);
  if (FAILED(hr)) {
    *error = WithCode("NEFORUM could not open this video.", hr);
    return false;
  }
  const DWORD stream = FindStreams(reader.Get()).video;
  ComPtr<IMFMediaType> native;
  if (stream == kNoStream || FAILED(reader->GetNativeMediaType(stream, 0, &native))) {
    *error = "This file has no video.";
    return false;
  }
  const int rotation = RotationOf(native.Get());
  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS), FALSE);
  reader->SetStreamSelection(stream, TRUE);
  ComPtr<IMFMediaType> rgb;
  hr = MFCreateMediaType(&rgb);
  if (SUCCEEDED(hr)) hr = rgb->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  if (SUCCEEDED(hr)) hr = rgb->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  if (SUCCEEDED(hr)) hr = reader->SetCurrentMediaType(stream, nullptr, rgb.Get());
  if (FAILED(hr)) {
    *error = WithCode("Windows cannot decode this kind of video on this PC.", hr);
    return false;
  }

  // Seeking lands on the key frame before the position; frames are decoded
  // from there up to the one shown at it. A position past the end takes the
  // last frame.
  const LONGLONG duration = DurationOf(reader.Get());
  LONGLONG target = std::max<int64_t>(0, position_ms) * 10000;
  if (duration > 0) target = std::min(target, std::max<LONGLONG>(0, duration - kTicksPerSecond / 10));
  if (target > 0) {
    PROPVARIANT position;
    PropVariantInit(&position);
    position.vt = VT_I8;
    position.hVal.QuadPart = target;
    reader->SetCurrentPosition(GUID_NULL, position);
    PropVariantClear(&position);
  }

  ComPtr<IMFSample> chosen;
  UINT32 width = 0;
  UINT32 height = 0;
  RECT picture = {};
  LONGLONG shown_at = -1;
  bool format_known = false;
  LONG stride = 0;
  // A few seconds of frames at most: key frames are seldom further apart.
  for (int read = 0; read < 600; read++) {
    DWORD flags = 0;
    LONGLONG time = 0;
    ComPtr<IMFSample> sample;
    hr = reader->ReadSample(stream, 0, nullptr, &flags, &time, &sample);
    if (FAILED(hr) || (flags & MF_SOURCE_READERF_ERROR)) break;
    if (!format_known || (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED)) {
      ComPtr<IMFMediaType> current;
      if (FAILED(reader->GetCurrentMediaType(stream, &current)) ||
          FAILED(MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, &width, &height)) || width == 0 ||
          height == 0 || width > 16384 || height > 16384) {
        chosen.Reset();
        break;
      }
      picture = PictureArea(current.Get(), width, height);
      UINT32 default_stride = 0;
      stride = SUCCEEDED(current->GetUINT32(MF_MT_DEFAULT_STRIDE, &default_stride))
                   ? static_cast<LONG>(default_stride)
                   : static_cast<LONG>(width * 4);
      format_known = true;
      // A frame decoded in the old format is not copied in the new one.
      chosen.Reset();
    }
    if (sample) {
      LONGLONG length = 0;
      if (FAILED(sample->GetSampleDuration(&length)) || length <= 0) length = kTicksPerSecond / 30;
      chosen = sample;
      shown_at = time;
      if (time + length > target) break;
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
  }
  std::vector<BYTE> rows;
  if (!chosen || !CopyFrameRows(chosen.Get(), width, height, stride, &rows)) {
    *error = "No frame of this video could be read.";
    return false;
  }

  // Cropped to the picture, turned upright and scaled down, by WIC.
  ComPtr<IWICImagingFactory> wic;
  ComPtr<IWICBitmap> bitmap;
  ComPtr<IWICBitmapClipper> clipper;
  ComPtr<IWICBitmapFlipRotator> rotator;
  ComPtr<IWICBitmapScaler> scaler;
  hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic));
  if (SUCCEEDED(hr)) {
    hr = wic->CreateBitmapFromMemory(width, height, GUID_WICPixelFormat32bppBGR, width * 4,
                                     static_cast<UINT>(rows.size()), rows.data(), &bitmap);
  }
  const WICRect area = {static_cast<INT>(picture.left), static_cast<INT>(picture.top),
                        static_cast<INT>(picture.right - picture.left), static_cast<INT>(picture.bottom - picture.top)};
  if (SUCCEEDED(hr)) hr = wic->CreateBitmapClipper(&clipper);
  if (SUCCEEDED(hr)) hr = clipper->Initialize(bitmap.Get(), &area);
  ComPtr<IWICBitmapSource> upright = clipper;
  if (SUCCEEDED(hr) && rotation != 0) {
    // Clockwise, the way players turn it.
    const WICBitmapTransformOptions turn = rotation == 90    ? WICBitmapTransformRotate90
                                           : rotation == 180 ? WICBitmapTransformRotate180
                                                             : WICBitmapTransformRotate270;
    hr = wic->CreateBitmapFlipRotator(&rotator);
    if (SUCCEEDED(hr)) hr = rotator->Initialize(clipper.Get(), turn);
    if (SUCCEEDED(hr)) upright = rotator;
  }
  UINT shown_width = 0;
  UINT shown_height = 0;
  if (SUCCEEDED(hr)) hr = upright->GetSize(&shown_width, &shown_height);
  ComPtr<IWICBitmapSource> result = upright;
  const UINT longest = std::max(shown_width, shown_height);
  const UINT limit = static_cast<UINT>(std::clamp(max_side, 16, 4096));
  if (SUCCEEDED(hr) && longest > limit) {
    const double scale = static_cast<double>(limit) / static_cast<double>(longest);
    shown_width = std::max(1u, static_cast<UINT>(shown_width * scale + 0.5));
    shown_height = std::max(1u, static_cast<UINT>(shown_height * scale + 0.5));
    hr = wic->CreateBitmapScaler(&scaler);
    if (SUCCEEDED(hr)) hr = scaler->Initialize(upright.Get(), shown_width, shown_height, WICBitmapInterpolationModeFant);
    if (SUCCEEDED(hr)) result = scaler;
  }
  if (SUCCEEDED(hr)) hr = EncodePng(wic.Get(), result.Get(), &frame->png);
  if (FAILED(hr)) {
    *error = WithCode("The frame could not be made into a picture.", hr);
    return false;
  }
  frame->width = static_cast<int>(shown_width);
  frame->height = static_cast<int>(shown_height);
  frame->position_ms = std::max<LONGLONG>(0, shown_at) / 10000;
  return true;
}

bool TranscodeVideoFile(const VideoTranscodeRequest& request,
                        const std::function<void(double)>& progress,
                        const std::atomic<bool>& cancelled, std::string* error_code,
                        std::string* error) {
  if (request.input_path.empty() || request.output_path.empty() ||
      request.input_path == request.output_path || request.video_bitrate == 0) {
    *error_code = "args";
    *error = "The video request is not complete.";
    return false;
  }
  VideoFileProbe probe;
  if (!ProbeVideoFile(request.input_path, &probe, error)) {
    *error_code = "probe";
    return false;
  }
  // The shown size, scaled down to |max_side| on its longest side, on even
  // sides (H.264 encoders take nothing else).
  const bool quarter = probe.rotation == 90 || probe.rotation == 270;
  const double shown_width = quarter ? probe.height : probe.width;
  const double shown_height = quarter ? probe.width : probe.height;
  const double limit = std::clamp(request.max_side, 16, 4096);
  const double scale = std::min(1.0, limit / std::max(shown_width, shown_height));
  const auto even = [](double side) { return std::clamp(static_cast<int>(side / 2.0 + 0.5) * 2, 16, 4096); };
  VideoCompositionRequest composition;
  composition.input_path = request.input_path;
  composition.output_path = request.output_path;
  composition.frame_width = even(shown_width * scale);
  composition.frame_height = even(shown_height * scale);
  composition.video_width = composition.frame_width;
  composition.video_height = composition.frame_height;
  composition.video_bitrate = request.video_bitrate;
  composition.audio_bitrate = request.audio_bitrate;
  return ComposeVideoFile(composition, progress, cancelled, error_code, error);
}

bool RenderStillVideoFile(const StillVideoRequest& request,
                          const std::function<void(double)>& progress,
                          const std::atomic<bool>& cancelled, std::string* error_code,
                          std::string* error) {
  const bool frame_ok = request.frame_width >= 16 && request.frame_height >= 16 &&
                        request.frame_width <= 4096 && request.frame_height <= 4096 &&
                        request.frame_width % 2 == 0 && request.frame_height % 2 == 0;
  if (!frame_ok || request.image_png.empty() || request.audio_path.empty() ||
      request.output_path.empty() || request.audio_path == request.output_path) {
    *error_code = "args";
    *error = "The video request is not complete.";
    return false;
  }
  bool ok = false;
  {
    MediaFoundationScope scope;
    if (!scope.started()) {
      *error_code = "unsupported";
      *error = "Windows Media Foundation is not available on this PC.";
      return false;
    }
    StillVideoWriter writer(request, progress, cancelled);
    ok = writer.Run(error_code, error);
  }
  if (!ok) DeleteFileW(request.output_path.c_str());
  return ok;
}

std::vector<std::string> AudioOutputFormats() {
  std::vector<std::string> formats;
  MediaFoundationScope scope;
  if (!scope.started()) return formats;
  if (EncoderAvailable(MFT_CATEGORY_AUDIO_ENCODER, MFMediaType_Audio, MFAudioFormat_AAC)) formats.push_back("m4a");
  if (EncoderAvailable(MFT_CATEGORY_AUDIO_ENCODER, MFMediaType_Audio, MFAudioFormat_MP3)) formats.push_back("mp3");
  return formats;
}

bool TranscodeAudioFile(const AudioTranscodeRequest& request,
                        const std::function<void(double)>& progress,
                        const std::atomic<bool>& cancelled, std::string* error_code,
                        std::string* error) {
  if ((request.format != "mp3" && request.format != "m4a") || request.input_path.empty() ||
      request.output_path.empty() || request.input_path == request.output_path) {
    *error_code = "args";
    *error = "The sound file request is not complete.";
    return false;
  }
  bool ok = false;
  {
    MediaFoundationScope scope;
    if (!scope.started()) {
      *error_code = "unsupported";
      *error = "Windows Media Foundation is not available on this PC.";
      return false;
    }
    AudioTranscoder transcoder(request, progress, cancelled);
    ok = transcoder.Run(error_code, error);
  }
  if (!ok) DeleteFileW(request.output_path.c_str());
  return ok;
}

struct VideoCompositor::Job {
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
  int64_t dart_id = 0;
  std::thread thread;
  // Written by the job's thread; read after it has been joined.
  bool ok = false;
  flutter::EncodableValue value;
  std::string error_code = "compose";
  std::string error_message;
};

VideoCompositor::VideoCompositor(flutter::BinaryMessenger* messenger) {
  const HINSTANCE instance = GetModuleHandleW(nullptr);
  WNDCLASSEXW window_class = {};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = &VideoCompositor::WindowProc;
  window_class.hInstance = instance;
  window_class.lpszClassName = kWindowClass;
  // Fails harmlessly when a previous compositor registered it.
  RegisterClassExW(&window_class);
  window_ = CreateWindowExW(0, kWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
                            instance, nullptr);
  if (window_) SetWindowLongPtrW(window_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "neforum/video", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        HandleMethodCall(call, std::move(result));
      });
}

VideoCompositor::~VideoCompositor() {
  closing_ = true;
  channel_->SetMethodCallHandler(nullptr);
  std::map<int, std::unique_ptr<Job>> jobs;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    jobs.swap(jobs_);
  }
  // Running compositions see |closing_| and stop at the next frame.
  for (auto& entry : jobs) {
    if (entry.second->thread.joinable()) entry.second->thread.join();
  }
  if (window_) {
    SetWindowLongPtrW(window_, GWLP_USERDATA, 0);
    DestroyWindow(window_);
  }
}

void VideoCompositor::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "isSupported") {
    if (!window_) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    Start(std::move(result), 0, [](Job& job, const Progress&) {
      job.value = flutter::EncodableValue(VideoCompositionSupported());
      job.ok = true;
    });
    return;
  }

  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  if (method == "probe") {
    const std::wstring path = args ? Wide(StringField(*args, "path")) : std::wstring();
    if (path.empty()) {
      result->Error("args", "No video was given.");
      return;
    }
    Start(std::move(result), 0, [path](Job& job, const Progress&) {
      VideoFileProbe probe;
      if (!ProbeVideoFile(path, &probe, &job.error_message)) {
        job.error_code = "probe";
        return;
      }
      job.value = flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("width"), flutter::EncodableValue(probe.width)},
          {flutter::EncodableValue("height"), flutter::EncodableValue(probe.height)},
          {flutter::EncodableValue("rotation"), flutter::EncodableValue(probe.rotation)},
          {flutter::EncodableValue("durationMs"), flutter::EncodableValue(probe.duration_ms)},
          {flutter::EncodableValue("hasAudio"), flutter::EncodableValue(probe.has_audio)},
      });
      job.ok = true;
    });
    return;
  }

  if (method == "compose") {
    if (!args) {
      result->Error("args", "The video request is not complete.");
      return;
    }
    VideoCompositionRequest request;
    request.input_path = Wide(StringField(*args, "inputPath"));
    request.output_path = Wide(StringField(*args, "outputPath"));
    request.overlay_png = BytesField(*args, "overlayPng");
    if (request.overlay_png.empty()) {
      result->Error("args", "The caption image is missing.");
      return;
    }
    request.frame_width = static_cast<int>(IntField(*args, "frameWidth"));
    request.frame_height = static_cast<int>(IntField(*args, "frameHeight"));
    request.video_left = static_cast<int>(IntField(*args, "videoLeft"));
    request.video_top = static_cast<int>(IntField(*args, "videoTop"));
    request.video_width = static_cast<int>(IntField(*args, "videoWidth"));
    request.video_height = static_cast<int>(IntField(*args, "videoHeight"));
    request.background_rgb = static_cast<uint32_t>(IntField(*args, "backgroundRgb")) & 0xFFFFFFu;
    Start(std::move(result), IntField(*args, "id"),
          [this, request = std::move(request)](Job& job, const Progress& progress) {
            if (!ComposeVideoFile(request, progress, closing_, &job.error_code,
                                  &job.error_message)) {
              return;
            }
            job.value = flutter::EncodableValue();
            job.ok = true;
          });
    return;
  }

  if (method == "frame") {
    const std::wstring path = args ? Wide(StringField(*args, "path")) : std::wstring();
    if (path.empty()) {
      result->Error("args", "No video was given.");
      return;
    }
    const int64_t position_ms = IntField(*args, "positionMs");
    const int max_side = static_cast<int>(std::clamp<int64_t>(IntField(*args, "maxSide"), 16, 4096));
    Start(std::move(result), 0, [path, position_ms, max_side](Job& job, const Progress&) {
      VideoFrameImage frame;
      if (!ReadVideoFrame(path, position_ms, max_side, &frame, &job.error_message)) {
        job.error_code = "frame";
        return;
      }
      job.value = flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("png"), flutter::EncodableValue(std::move(frame.png))},
          {flutter::EncodableValue("width"), flutter::EncodableValue(frame.width)},
          {flutter::EncodableValue("height"), flutter::EncodableValue(frame.height)},
          {flutter::EncodableValue("positionMs"), flutter::EncodableValue(frame.position_ms)},
      });
      job.ok = true;
    });
    return;
  }

  if (method == "audioFormats") {
    Start(std::move(result), 0, [](Job& job, const Progress&) {
      flutter::EncodableList formats;
      for (const auto& format : AudioOutputFormats()) formats.emplace_back(format);
      job.value = flutter::EncodableValue(std::move(formats));
      job.ok = true;
    });
    return;
  }

  if (!args) {
    result->Error("args", "The request is not complete.");
    return;
  }

  if (method == "transcode") {
    VideoTranscodeRequest request;
    request.input_path = Wide(StringField(*args, "inputPath"));
    request.output_path = Wide(StringField(*args, "outputPath"));
    request.video_bitrate = BitrateField(*args, "videoBitrate");
    request.audio_bitrate = BitrateField(*args, "audioBitrate");
    request.max_side = static_cast<int>(std::clamp<int64_t>(IntField(*args, "maxSide"), 16, 4096));
    Start(std::move(result), IntField(*args, "id"),
          [this, request = std::move(request)](Job& job, const Progress& progress) {
            if (!TranscodeVideoFile(request, progress, closing_, &job.error_code, &job.error_message)) return;
            job.value = flutter::EncodableValue();
            job.ok = true;
          });
    return;
  }

  if (method == "audioVideo") {
    StillVideoRequest request;
    request.audio_path = Wide(StringField(*args, "audioPath"));
    request.output_path = Wide(StringField(*args, "outputPath"));
    request.image_png = BytesField(*args, "imagePng");
    request.frame_width = static_cast<int>(IntField(*args, "frameWidth"));
    request.frame_height = static_cast<int>(IntField(*args, "frameHeight"));
    request.audio_bitrate = BitrateField(*args, "audioBitrate");
    Start(std::move(result), IntField(*args, "id"),
          [this, request = std::move(request)](Job& job, const Progress& progress) {
            if (!RenderStillVideoFile(request, progress, closing_, &job.error_code, &job.error_message)) return;
            job.value = flutter::EncodableValue();
            job.ok = true;
          });
    return;
  }

  if (method == "transcodeAudio") {
    AudioTranscodeRequest request;
    request.input_path = Wide(StringField(*args, "inputPath"));
    request.output_path = Wide(StringField(*args, "outputPath"));
    request.format = StringField(*args, "format");
    request.bitrate = BitrateField(*args, "bitrate");
    Start(std::move(result), IntField(*args, "id"),
          [this, request = std::move(request)](Job& job, const Progress& progress) {
            if (!TranscodeAudioFile(request, progress, closing_, &job.error_code, &job.error_message)) return;
            job.value = flutter::EncodableValue();
            job.ok = true;
          });
    return;
  }

  result->NotImplemented();
}

void VideoCompositor::Start(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result, int64_t dart_id,
    Work work) {
  if (!window_) {
    // Without the window no answer could come back.
    result->Error("unsupported", "The video compositor could not start.");
    return;
  }
  std::lock_guard<std::mutex> lock(mutex_);
  const int id = ++last_job_;
  auto job = std::make_unique<Job>();
  Job* running = job.get();
  job->result = std::move(result);
  job->dart_id = dart_id;
  jobs_[id] = std::move(job);
  const HWND window = window_;
  running->thread = std::thread([running, id, window, work = std::move(work)]() {
    const Progress progress = [id, window](double value) {
      PostMessageW(window, kProgressMessage, static_cast<WPARAM>(id),
                   static_cast<LPARAM>(value * 1000.0 + 0.5));
    };
    work(*running, progress);
    PostMessageW(window, kDoneMessage, static_cast<WPARAM>(id), 0);
  });
}

void VideoCompositor::Finish(int job_id) {
  std::unique_ptr<Job> job;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto it = jobs_.find(job_id);
    if (it == jobs_.end()) return;
    job = std::move(it->second);
    jobs_.erase(it);
  }
  if (job->thread.joinable()) job->thread.join();
  if (job->ok) {
    job->result->Success(job->value);
  } else {
    job->result->Error(job->error_code, job->error_message);
  }
}

void VideoCompositor::ReportProgress(int job_id, int permille) {
  int64_t dart_id = 0;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto it = jobs_.find(job_id);
    if (it == jobs_.end()) return;
    dart_id = it->second->dart_id;
  }
  if (dart_id == 0) return;
  channel_->InvokeMethod(
      "progress", std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                      {flutter::EncodableValue("id"), flutter::EncodableValue(dart_id)},
                      {flutter::EncodableValue("progress"),
                       flutter::EncodableValue(static_cast<double>(permille) / 1000.0)},
                  }));
}

LRESULT CALLBACK VideoCompositor::WindowProc(HWND window, UINT message, WPARAM wparam,
                                             LPARAM lparam) {
  auto* self = reinterpret_cast<VideoCompositor*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (self && message == kDoneMessage) {
    self->Finish(static_cast<int>(wparam));
    return 0;
  }
  if (self && message == kProgressMessage) {
    self->ReportProgress(static_cast<int>(wparam), static_cast<int>(lparam));
    return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}
