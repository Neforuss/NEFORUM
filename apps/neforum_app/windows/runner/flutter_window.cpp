#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shlobj.h>

#include <cstring>
#include <optional>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Copies |bytes| into a movable global block for SetClipboardData.
HGLOBAL GlobalCopy(const void* bytes, size_t size, size_t extra_zeroes = 0) {
  HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, size + extra_zeroes);
  if (!mem) return nullptr;
  void* p = GlobalLock(mem);
  if (!p) {
    GlobalFree(mem);
    return nullptr;
  }
  if (size > 0) memcpy(p, bytes, size);
  GlobalUnlock(mem);
  return mem;
}

bool SetData(UINT format, HGLOBAL mem) {
  if (!mem) return false;
  if (SetClipboardData(format, mem)) return true;
  GlobalFree(mem);
  return false;
}

const std::vector<uint8_t>* Bytes(const flutter::EncodableMap& args, const char* key) {
  auto it = args.find(flutter::EncodableValue(key));
  return it == args.end() ? nullptr : std::get_if<std::vector<uint8_t>>(&it->second);
}

// Puts a picture on the clipboard: "PNG" (what browsers read on paste),
// CF_DIB (for apps that only take bitmaps) and, when |path| names a file,
// CF_HDROP (the original file, for places that accept pasted files).
bool CopyImage(HWND owner, const flutter::EncodableMap& args) {
  const auto* png = Bytes(args, "png");
  const auto* dib = Bytes(args, "dib");
  std::wstring path;
  auto p = args.find(flutter::EncodableValue("path"));
  if (p != args.end()) {
    if (const auto* s = std::get_if<std::string>(&p->second); s && !s->empty()) {
      int n = MultiByteToWideChar(CP_UTF8, 0, s->c_str(), -1, nullptr, 0);
      if (n > 1) {
        path.resize(n - 1);
        MultiByteToWideChar(CP_UTF8, 0, s->c_str(), -1, path.data(), n);
      }
      if (GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES) path.clear();
    }
  }
  if ((!png || png->empty()) && (!dib || dib->empty()) && path.empty()) return false;

  // Another program may hold the clipboard for a moment.
  bool open = false;
  for (int i = 0; i < 10 && !(open = OpenClipboard(owner) != FALSE); i++) Sleep(25);
  if (!open) return false;
  EmptyClipboard();
  bool any = false;
  if (png && !png->empty()) {
    any |= SetData(RegisterClipboardFormatW(L"PNG"), GlobalCopy(png->data(), png->size()));
  }
  if (dib && !dib->empty()) {
    any |= SetData(CF_DIB, GlobalCopy(dib->data(), dib->size()));
  }
  if (!path.empty()) {
    // DROPFILES, then the path, then two terminating zeroes (from ZEROINIT).
    std::vector<uint8_t> drop(sizeof(DROPFILES) + path.size() * sizeof(wchar_t));
    auto* df = reinterpret_cast<DROPFILES*>(drop.data());
    df->pFiles = sizeof(DROPFILES);
    df->fWide = TRUE;
    memcpy(drop.data() + sizeof(DROPFILES), path.c_str(), path.size() * sizeof(wchar_t));
    any |= SetData(CF_HDROP, GlobalCopy(drop.data(), drop.size(), 2 * sizeof(wchar_t)));
  }
  CloseClipboard();
  return any;
}

std::vector<uint8_t> GlobalBytes(HANDLE h) {
  std::vector<uint8_t> out;
  if (!h) return out;
  const SIZE_T size = GlobalSize(h);
  const void* p = GlobalLock(h);
  if (p && size > 0) out.assign(static_cast<const uint8_t*>(p), static_cast<const uint8_t*>(p) + size);
  if (p) GlobalUnlock(h);
  return out;
}

std::string Utf8(const std::wstring& w) {
  if (w.empty()) return std::string();
  int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
  std::string out(n, '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.c_str(), static_cast<int>(w.size()), out.data(), n, nullptr, nullptr);
  return out;
}

// What a paste into the composer can attach: copied files (Explorer),
// "PNG" (browsers, Snipping Tool) or a bitmap (CF_DIBV5 / CF_DIB). Returns
// an empty map when the clipboard holds none of them.
flutter::EncodableMap ReadImage(HWND owner) {
  flutter::EncodableMap out;
  bool open = false;
  for (int i = 0; i < 10 && !(open = OpenClipboard(owner) != FALSE); i++) Sleep(25);
  if (!open) return out;
  if (HANDLE drop = GetClipboardData(CF_HDROP)) {
    flutter::EncodableList files;
    HDROP hdrop = static_cast<HDROP>(drop);
    const UINT count = DragQueryFileW(hdrop, 0xFFFFFFFF, nullptr, 0);
    for (UINT i = 0; i < count; i++) {
      const UINT len = DragQueryFileW(hdrop, i, nullptr, 0);
      std::wstring path(len, L'\0');
      DragQueryFileW(hdrop, i, path.data(), len + 1);
      files.push_back(flutter::EncodableValue(Utf8(path)));
    }
    if (!files.empty()) out[flutter::EncodableValue("files")] = flutter::EncodableValue(files);
  }
  if (out.empty()) {
    const UINT png = RegisterClipboardFormatW(L"PNG");
    if (IsClipboardFormatAvailable(png)) {
      auto bytes = GlobalBytes(GetClipboardData(png));
      if (!bytes.empty()) out[flutter::EncodableValue("png")] = flutter::EncodableValue(bytes);
    }
  }
  if (out.empty()) {
    for (UINT format : {static_cast<UINT>(CF_DIBV5), static_cast<UINT>(CF_DIB)}) {
      if (!IsClipboardFormatAvailable(format)) continue;
      auto bytes = GlobalBytes(GetClipboardData(format));
      if (!bytes.empty()) {
        out[flutter::EncodableValue("dib")] = flutter::EncodableValue(bytes);
        break;
      }
    }
  }
  CloseClipboard();
  return out;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  clipboard_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "neforum/clipboard",
      &flutter::StandardMethodCodec::GetInstance());
  clipboard_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "readImage") {
          result->Success(flutter::EncodableValue(ReadImage(GetHandle())));
          return;
        }
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (call.method_name() != "copyImage" || !args) {
          result->NotImplemented();
          return;
        }
        result->Success(flutter::EncodableValue(CopyImage(GetHandle(), *args)));
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  clipboard_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
