#include "flutter_window.h"

#include <wininet.h>

#include <cwchar>
#include <optional>
#include <string>
#include <variant>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

// Posted to ourselves by "quit" so the window is destroyed outside the
// method-channel callback (which runs inside the Flutter controller).
constexpr UINT kQuitMessage = WM_APP + 0x51;

constexpr wchar_t kInternetSettingsKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return std::wstring();
  const int len = MultiByteToWideChar(CP_UTF8, 0, s.data(),
                                      static_cast<int>(s.size()), nullptr, 0);
  if (len <= 0) return std::wstring();
  std::wstring out(static_cast<size_t>(len), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                      out.data(), len);
  return out;
}

std::string WideToUtf8(const std::wstring& w) {
  if (w.empty()) return std::string();
  const int len = WideCharToMultiByte(CP_UTF8, 0, w.data(),
                                      static_cast<int>(w.size()), nullptr, 0,
                                      nullptr, nullptr);
  if (len <= 0) return std::string();
  std::string out(static_cast<size_t>(len), '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()),
                      out.data(), len, nullptr, nullptr);
  return out;
}

const EncodableValue* Field(const EncodableMap& map, const char* key) {
  const auto it = map.find(EncodableValue(std::string(key)));
  return it == map.end() ? nullptr : &it->second;
}

std::string StringField(const EncodableMap& map, const char* key) {
  const EncodableValue* v = Field(map, key);
  if (v == nullptr) return std::string();
  if (const auto* s = std::get_if<std::string>(v)) return *s;
  return std::string();
}

int64_t IntField(const EncodableMap& map, const char* key) {
  const EncodableValue* v = Field(map, key);
  if (v == nullptr) return 0;
  if (const auto* i = std::get_if<int32_t>(v)) return *i;
  if (const auto* l = std::get_if<int64_t>(v)) return *l;
  if (const auto* b = std::get_if<bool>(v)) return *b ? 1 : 0;
  return 0;
}

bool ReadRegString(HKEY key, const wchar_t* name, std::wstring* out) {
  DWORD type = 0;
  DWORD size = 0;
  if (RegQueryValueExW(key, name, nullptr, &type, nullptr, &size) !=
          ERROR_SUCCESS ||
      (type != REG_SZ && type != REG_EXPAND_SZ)) {
    return false;
  }
  std::wstring buffer(size / sizeof(wchar_t) + 1, L'\0');
  if (RegQueryValueExW(key, name, nullptr, &type,
                       reinterpret_cast<LPBYTE>(buffer.data()), &size) !=
      ERROR_SUCCESS) {
    return false;
  }
  buffer.resize(wcsnlen(buffer.c_str(), buffer.size()));
  *out = buffer;
  return true;
}

void WriteRegString(HKEY key, const wchar_t* name, const std::wstring& value) {
  RegSetValueExW(key, name, 0, REG_SZ,
                 reinterpret_cast<const BYTE*>(value.c_str()),
                 static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
}

ProxySnapshot ReadProxy() {
  ProxySnapshot snapshot;
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kInternetSettingsKey, 0, KEY_READ,
                    &key) != ERROR_SUCCESS) {
    return snapshot;
  }
  DWORD type = 0;
  DWORD value = 0;
  DWORD size = sizeof(value);
  if (RegQueryValueExW(key, L"ProxyEnable", nullptr, &type,
                       reinterpret_cast<LPBYTE>(&value),
                       &size) == ERROR_SUCCESS &&
      type == REG_DWORD) {
    snapshot.enable = value;
  }
  ReadRegString(key, L"ProxyServer", &snapshot.server);
  ReadRegString(key, L"ProxyOverride", &snapshot.bypass);
  snapshot.has_auto_config_url =
      ReadRegString(key, L"AutoConfigURL", &snapshot.auto_config_url);
  RegCloseKey(key);
  return snapshot;
}

bool WriteProxy(const ProxySnapshot& snapshot) {
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kInternetSettingsKey, 0,
                    KEY_SET_VALUE, &key) != ERROR_SUCCESS) {
    return false;
  }
  const DWORD enable = snapshot.enable;
  RegSetValueExW(key, L"ProxyEnable", 0, REG_DWORD,
                 reinterpret_cast<const BYTE*>(&enable), sizeof(enable));
  WriteRegString(key, L"ProxyServer", snapshot.server);
  WriteRegString(key, L"ProxyOverride", snapshot.bypass);
  if (snapshot.has_auto_config_url) {
    WriteRegString(key, L"AutoConfigURL", snapshot.auto_config_url);
  } else {
    RegDeleteValueW(key, L"AutoConfigURL");
  }
  RegCloseKey(key);
  // Tell WinINet (and so browsers already running) to re-read the settings.
  InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
  InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
  return true;
}

EncodableValue SnapshotToValue(const ProxySnapshot& s) {
  EncodableMap map;
  map[EncodableValue("enable")] = EncodableValue(static_cast<int32_t>(s.enable));
  map[EncodableValue("server")] = EncodableValue(WideToUtf8(s.server));
  map[EncodableValue("bypass")] = EncodableValue(WideToUtf8(s.bypass));
  map[EncodableValue("autoConfigUrl")] =
      s.has_auto_config_url ? EncodableValue(WideToUtf8(s.auto_config_url))
                            : EncodableValue();
  return EncodableValue(map);
}

ProxySnapshot SnapshotFromMap(const EncodableMap& map) {
  ProxySnapshot s;
  s.enable = IntField(map, "enable") != 0 ? 1 : 0;
  s.server = Utf8ToWide(StringField(map, "server"));
  s.bypass = Utf8ToWide(StringField(map, "bypass"));
  const EncodableValue* pac = Field(map, "autoConfigUrl");
  if (pac != nullptr) {
    if (const auto* url = std::get_if<std::string>(pac)) {
      s.has_auto_config_url = true;
      s.auto_config_url = Utf8ToWide(*url);
    }
  }
  return s;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool start_hidden)
    : project_(project), start_hidden_(start_hidden) {}

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

  activate_message_ = RegisterWindowMessageW(PURECONNECT_ACTIVATE_MESSAGE);
  // Let a non-elevated second launch reach us when we run as administrator.
  ChangeWindowMessageFilterEx(GetHandle(), activate_message_, MSGFLT_ALLOW,
                              nullptr);

  window_channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      flutter_controller_->engine()->messenger(), "pureconnect/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        HandleWindowCall(call, std::move(result));
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!start_hidden_) {
      this->Show();
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::HandleWindowCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();
  const EncodableValue* args = call.arguments();

  if (method == "setIcon") {
    const auto* path = args ? std::get_if<std::string>(args) : nullptr;
    result->Success(EncodableValue(path != nullptr && SetIconFromFile(*path)));
  } else if (method == "show") {
    start_hidden_ = false;
    ShowAndFocus();
    result->Success(EncodableValue(true));
  } else if (method == "hide") {
    ShowWindow(GetHandle(), SW_HIDE);
    result->Success(EncodableValue(true));
  } else if (method == "isVisible") {
    result->Success(EncodableValue(IsWindowVisible(GetHandle()) != FALSE));
  } else if (method == "setPreventClose") {
    const auto* value = args ? std::get_if<bool>(args) : nullptr;
    prevent_close_ = value != nullptr && *value;
    result->Success(EncodableValue(true));
  } else if (method == "quit") {
    prevent_close_ = false;
    PostMessage(GetHandle(), kQuitMessage, 0, 0);
    result->Success(EncodableValue(true));
  } else if (method == "proxyGet") {
    result->Success(SnapshotToValue(ReadProxy()));
  } else if (method == "proxySet") {
    const auto* map = args ? std::get_if<EncodableMap>(args) : nullptr;
    result->Success(EncodableValue(map != nullptr && WriteProxy(SnapshotFromMap(*map))));
  } else if (method == "proxyGuard") {
    const auto* map = args ? std::get_if<EncodableMap>(args) : nullptr;
    if (map != nullptr) {
      proxy_guard_ = SnapshotFromMap(*map);
    } else {
      proxy_guard_.reset();
    }
    result->Success(EncodableValue(true));
  } else {
    result->NotImplemented();
  }
}

bool FlutterWindow::SetIconFromFile(const std::string& path) {
  const std::wstring wpath = Utf8ToWide(path);
  HICON big_icon = static_cast<HICON>(
      LoadImageW(nullptr, wpath.c_str(), IMAGE_ICON, GetSystemMetrics(SM_CXICON),
                 GetSystemMetrics(SM_CYICON), LR_LOADFROMFILE));
  HICON small_icon = static_cast<HICON>(LoadImageW(
      nullptr, wpath.c_str(), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
      GetSystemMetrics(SM_CYSMICON), LR_LOADFROMFILE));
  if (!big_icon || !small_icon) {
    if (big_icon) DestroyIcon(big_icon);
    if (small_icon) DestroyIcon(small_icon);
    return false;
  }
  HWND hwnd = GetHandle();
  SendMessage(hwnd, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(big_icon));
  SendMessage(hwnd, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(small_icon));
  if (big_icon_) DestroyIcon(big_icon_);
  if (small_icon_) DestroyIcon(small_icon_);
  big_icon_ = big_icon;
  small_icon_ = small_icon;
  return true;
}

void FlutterWindow::ShowAndFocus() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) return;
  if (IsIconic(hwnd)) {
    ShowWindow(hwnd, SW_RESTORE);
  } else {
    ShowWindow(hwnd, SW_SHOW);
  }
  SetForegroundWindow(hwnd);
}

void FlutterWindow::Notify(const std::string& method) {
  if (window_channel_) {
    window_channel_->InvokeMethod(method, nullptr);
  }
}

void FlutterWindow::OnDestroy() {
  window_channel_ = nullptr;
  if (big_icon_) DestroyIcon(big_icon_);
  if (small_icon_) DestroyIcon(small_icon_);
  big_icon_ = small_icon_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == kQuitMessage) {
    DestroyWindow(hwnd);
    return 0;
  }
  if (activate_message_ != 0 && message == activate_message_) {
    // A second launch: show the window of this (single) instance.
    start_hidden_ = false;
    ShowAndFocus();
    Notify("activate");
    return 0;
  }
  if (message == WM_CLOSE && prevent_close_) {
    // Dart hides to the tray, or cleans up (system proxy, core) and quits.
    Notify("close");
    return 0;
  }
  if (message == WM_ENDSESSION && wparam && proxy_guard_) {
    // Logoff/shutdown: Dart won't get to run, put the old proxy back now.
    WriteProxy(*proxy_guard_);
    proxy_guard_.reset();
  }

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
