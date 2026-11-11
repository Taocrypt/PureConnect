#include "flutter_window.h"

#include <wininet.h>
#include <knownfolders.h>
#include <shlobj.h>
#include <shellapi.h>
#include <strsafe.h>
#include <shobjidl.h>

#include <cwchar>
#include <filesystem>
#include <optional>
#include <string>
#include <variant>
#include <vector>

#include <dwmapi.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

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


// Number of app icons embedded in pureconnect.exe (Runner.rc).
constexpr int kAppIconCount = 4;

std::wstring ModulePath() {
  wchar_t buf[MAX_PATH * 4];
  const DWORD n = GetModuleFileNameW(nullptr, buf, ARRAYSIZE(buf));
  return std::wstring(buf, n);
}

std::wstring KnownFolder(REFKNOWNFOLDERID id) {
  PWSTR path = nullptr;
  std::wstring out;
  if (SUCCEEDED(SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, nullptr, &path))) {
    out = path;
  }
  CoTaskMemFree(path);
  return out;
}

// Points every PureConnect shortcut (.lnk whose target is this exe) in the
// Start Menu, on the desktop and pinned to the taskbar at icon [index] of
// pureconnect.exe. Explorer takes the taskbar / Start icon from the shortcut
// the app was started from, not from WM_SETICON, so this is what makes the
// choice stick there (after the next start). Shortcuts in all-users folders
// need administrator rights; those are counted as failed.
EncodableMap UpdateShortcutIcons(int index) {
  int updated = 0, failed = 0, found = 0;
  const std::wstring exe = ModulePath();
  std::vector<std::wstring> roots = {
      KnownFolder(FOLDERID_Programs), KnownFolder(FOLDERID_CommonPrograms),
      KnownFolder(FOLDERID_Desktop), KnownFolder(FOLDERID_PublicDesktop),
  };
  const std::wstring appdata = KnownFolder(FOLDERID_RoamingAppData);
  if (!appdata.empty()) {
    roots.push_back(appdata +
                    L"\\Microsoft\\Internet Explorer\\Quick Launch\\User Pinned");
  }
  IShellLinkW* link = nullptr;
  if (FAILED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&link)))) {
    return EncodableMap{{EncodableValue("updated"), EncodableValue(0)},
                        {EncodableValue("failed"), EncodableValue(-1)},
                        {EncodableValue("found"), EncodableValue(0)}};
  }
  IPersistFile* file = nullptr;
  link->QueryInterface(IID_PPV_ARGS(&file));
  namespace fs = std::filesystem;
  for (const auto& root : roots) {
    if (root.empty() || file == nullptr) continue;
    std::error_code ec;
    fs::recursive_directory_iterator it(
        root, fs::directory_options::skip_permission_denied, ec), end;
    for (; !ec && it != end; it.increment(ec)) {
      if (it.depth() > 3) {
        it.disable_recursion_pending();
        continue;
      }
      const fs::path& p = it->path();
      if (_wcsicmp(p.extension().c_str(), L".lnk") != 0) continue;
      if (FAILED(file->Load(p.c_str(), STGM_READWRITE))) continue;
      wchar_t target[MAX_PATH * 4] = {0};
      if (FAILED(link->GetPath(target, ARRAYSIZE(target), nullptr, SLGP_RAWPATH)) ||
          _wcsicmp(target, exe.c_str()) != 0) {
        continue;
      }
      found++;
      wchar_t icon_path[MAX_PATH * 4] = {0};
      int icon_index = 0;
      link->GetIconLocation(icon_path, ARRAYSIZE(icon_path), &icon_index);
      const bool same = icon_index == index &&
                        (_wcsicmp(icon_path, exe.c_str()) == 0 ||
                         (icon_path[0] == 0 && index == 0));
      if (same) {
        updated++;
        continue;
      }
      if (SUCCEEDED(link->SetIconLocation(exe.c_str(), index)) &&
          SUCCEEDED(file->Save(p.c_str(), TRUE))) {
        updated++;
        SHChangeNotify(SHCNE_UPDATEITEM, SHCNF_PATHW, p.c_str(), nullptr);
      } else {
        failed++;
      }
    }
  }
  if (file != nullptr) file->Release();
  link->Release();
  if (updated > 0) SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
  return EncodableMap{{EncodableValue("updated"), EncodableValue(updated)},
                      {EncodableValue("failed"), EncodableValue(failed)},
                      {EncodableValue("found"), EncodableValue(found)}};
}


// --- in-process replacements for helper processes (no PowerShell, reg.exe
// or cmd.exe children; security software flags hidden PowerShell) ---------

constexpr UINT kTrayIconId = 1;          // the tray plugin's icon
constexpr UINT kNotifyIconId = 0x504e;   // temporary icon for a notification
constexpr UINT_PTR kNotifyTimerId = 0x504e;
constexpr wchar_t kRunKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";

std::string StringArg(const EncodableMap& map, const char* key) {
  const auto it = map.find(EncodableValue(key));
  if (it == map.end()) return std::string();
  const auto* s = std::get_if<std::string>(&it->second);
  return s ? *s : std::string();
}

// Whether this process runs elevated (replaces `net session`).
bool IsProcessElevated() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
  TOKEN_ELEVATION elevation{};
  DWORD size = 0;
  const bool ok = GetTokenInformation(token, TokenElevation, &elevation,
                                      sizeof(elevation), &size) != FALSE;
  CloseHandle(token);
  return ok && elevation.TokenIsElevated != 0;
}

// Starts [file] elevated (UAC prompt) without a window (replaces PowerShell
// Start-Process -Verb RunAs). Returns {ok, cancelled, error}.
EncodableMap RunElevated(HWND owner, const EncodableMap& args) {
  const std::wstring file = Utf8ToWide(StringArg(args, "file"));
  const std::wstring params = Utf8ToWide(StringArg(args, "args"));
  const std::wstring dir = Utf8ToWide(StringArg(args, "dir"));
  SHELLEXECUTEINFOW info{};
  info.cbSize = sizeof(info);
  info.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
  info.hwnd = owner;
  info.lpVerb = L"runas";
  info.lpFile = file.c_str();
  info.lpParameters = params.empty() ? nullptr : params.c_str();
  info.lpDirectory = dir.empty() ? nullptr : dir.c_str();
  info.nShow = SW_HIDE;  // the core is a console program
  const bool ok = ShellExecuteExW(&info) != FALSE;
  const DWORD error = ok ? 0 : GetLastError();
  return EncodableMap{
      {EncodableValue("ok"), EncodableValue(ok)},
      {EncodableValue("cancelled"), EncodableValue(error == ERROR_CANCELLED)},
      {EncodableValue("error"), EncodableValue(static_cast<int>(error))}};
}

// HKCU Run entry (replaces reg.exe). Null when absent.
EncodableValue AutostartGet(const std::wstring& name) {
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_READ, &key) != ERROR_SUCCESS) {
    return EncodableValue();
  }
  std::wstring value;
  const bool found = ReadRegString(key, name.c_str(), &value);
  RegCloseKey(key);
  return found ? EncodableValue(WideToUtf8(value)) : EncodableValue();
}

// Sets ([value] non-empty) or removes the HKCU Run entry.
bool AutostartSet(const std::wstring& name, const std::wstring& value) {
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0,
                      KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
    return false;
  }
  LSTATUS r;
  if (value.empty()) {
    r = RegDeleteValueW(key, name.c_str());
    if (r == ERROR_FILE_NOT_FOUND) r = ERROR_SUCCESS;
  } else {
    r = RegSetValueExW(key, name.c_str(), 0, REG_SZ,
                       reinterpret_cast<const BYTE*>(value.c_str()),
                       static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
  }
  RegCloseKey(key);
  return r == ERROR_SUCCESS;
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
  frame_.Attach(GetHandle(), flutter_controller_->view()->GetNativeWindow());
  was_maximized_ = frame_.IsMaximized();

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
    // An int is the index of an icon embedded in pureconnect.exe; a string
    // a .ico file (kept for compatibility).
    const auto* index = args ? std::get_if<int>(args) : nullptr;
    const auto* path = args ? std::get_if<std::string>(args) : nullptr;
    bool ok = false;
    if (index != nullptr) {
      ok = SetIconFromResource(*index);
    } else if (path != nullptr) {
      ok = SetIconFromFile(*path);
    }
    result->Success(EncodableValue(ok));
  } else if (method == "notify") {
    const auto* map = args ? std::get_if<EncodableMap>(args) : nullptr;
    result->Success(EncodableValue(
        map != nullptr && ShowNotification(Utf8ToWide(StringArg(*map, "title")),
                                           Utf8ToWide(StringArg(*map, "body")))));
  } else if (method == "isElevated") {
    result->Success(EncodableValue(IsProcessElevated()));
  } else if (method == "runElevated") {
    const auto* map = args ? std::get_if<EncodableMap>(args) : nullptr;
    if (map == nullptr) {
      result->Success(EncodableValue());
    } else {
      result->Success(EncodableValue(RunElevated(GetHandle(), *map)));
    }
  } else if (method == "autostartGet") {
    const auto* name = args ? std::get_if<std::string>(args) : nullptr;
    result->Success(name ? AutostartGet(Utf8ToWide(*name)) : EncodableValue());
  } else if (method == "autostartSet") {
    const auto* map = args ? std::get_if<EncodableMap>(args) : nullptr;
    result->Success(EncodableValue(
        map != nullptr && AutostartSet(Utf8ToWide(StringArg(*map, "name")),
                                       Utf8ToWide(StringArg(*map, "value")))));
  } else if (method == "setShortcutIcon") {
    const auto* index = args ? std::get_if<int>(args) : nullptr;
    if (index == nullptr || *index < 0 || *index >= kAppIconCount) {
      result->Success(EncodableValue());
    } else {
      result->Success(EncodableValue(UpdateShortcutIcons(*index)));
    }
  } else if (method == "minimize") {
    PostMessage(GetHandle(), WM_SYSCOMMAND, SC_MINIMIZE, 0);
    result->Success(EncodableValue(true));
  } else if (method == "maximize") {
    if (!frame_.IsMaximized()) PostMessage(GetHandle(), WM_SYSCOMMAND, SC_MAXIMIZE, 0);
    result->Success(EncodableValue(true));
  } else if (method == "unmaximize") {
    if (frame_.IsMaximized()) PostMessage(GetHandle(), WM_SYSCOMMAND, SC_RESTORE, 0);
    result->Success(EncodableValue(true));
  } else if (method == "isMaximized") {
    result->Success(EncodableValue(frame_.IsMaximized()));
  } else if (method == "startDragging") {
    ReleaseCapture();
    SendMessage(GetHandle(), WM_SYSCOMMAND, SC_MOVE | HTCAPTION, 0);
    result->Success(EncodableValue(true));
  } else if (method == "setAlwaysOnTop") {
    const auto* value = args ? std::get_if<bool>(args) : nullptr;
    SetWindowPos(GetHandle(), value != nullptr && *value ? HWND_TOPMOST : HWND_NOTOPMOST,
                 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    result->Success(EncodableValue(true));
  } else if (method == "isAlwaysOnTop") {
    result->Success(EncodableValue(
        (GetWindowLongW(GetHandle(), GWL_EXSTYLE) & WS_EX_TOPMOST) != 0));
  } else if (method == "setEffect") {
    const auto* map = args ? std::get_if<EncodableMap>(args) : nullptr;
    bool ok = false;
    if (map != nullptr) {
      ok = frame_.SetBlur(IntField(*map, "enabled") != 0,
                          static_cast<uint32_t>(IntField(*map, "tint")),
                          IntField(*map, "dark") != 0);
    }
    result->Success(EncodableValue(ok));
  } else if (method == "systemAccent") {
    // The accent colour (DWM colorization), 0xAARRGGBB.
    DWORD color = 0;
    BOOL opaque = FALSE;
    if (SUCCEEDED(DwmGetColorizationColor(&color, &opaque))) {
      result->Success(EncodableValue(static_cast<int64_t>(color | 0xFF000000u)));
    } else {
      result->Success(EncodableValue());
    }
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

// A notification as a tray balloon (Windows 10/11 show it as a toast under
// PureConnect's name and icon). Uses the tray icon when it is there, else a
// temporary icon removed again after a while.
bool FlutterWindow::ShowNotification(const std::wstring& title,
                                     const std::wstring& body) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) return false;
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = hwnd;
  data.uID = kTrayIconId;
  data.uFlags = NIF_INFO;
  data.dwInfoFlags = NIIF_USER | NIIF_LARGE_ICON;
  HICON large = static_cast<HICON>(LoadImageW(
      GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), LR_SHARED));
  data.hBalloonIcon = large;
  StringCchCopyW(data.szInfoTitle, ARRAYSIZE(data.szInfoTitle), title.c_str());
  StringCchCopyW(data.szInfo, ARRAYSIZE(data.szInfo),
                 body.empty() ? L" " : body.c_str());
  if (Shell_NotifyIconW(NIM_MODIFY, &data)) return true;

  // No tray icon (hidden or not created): a temporary one.
  data.uID = kNotifyIconId;
  data.uFlags = NIF_INFO | NIF_ICON | NIF_TIP;
  data.hIcon = static_cast<HICON>(LoadImageW(
      GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_SHARED));
  StringCchCopyW(data.szTip, ARRAYSIZE(data.szTip), L"PureConnect");
  if (!notify_icon_added_) {
    if (!Shell_NotifyIconW(NIM_ADD, &data)) return false;
    notify_icon_added_ = true;
  } else if (!Shell_NotifyIconW(NIM_MODIFY, &data)) {
    return false;
  }
  SetTimer(hwnd, kNotifyTimerId, 15000, nullptr);
  return true;
}

void FlutterWindow::RemoveNotifyIcon() {
  KillTimer(GetHandle(), kNotifyTimerId);
  if (!notify_icon_added_) return;
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = GetHandle();
  data.uID = kNotifyIconId;
  Shell_NotifyIconW(NIM_DELETE, &data);
  notify_icon_added_ = false;
}

bool FlutterWindow::SetIconFromResource(int index) {
  if (index < 0 || index >= kAppIconCount) return false;
  HINSTANCE module = GetModuleHandle(nullptr);
  HICON big_icon = static_cast<HICON>(LoadImageW(
      module, MAKEINTRESOURCEW(IDI_APP_ICON + index), IMAGE_ICON,
      GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), LR_DEFAULTCOLOR));
  HICON small_icon = static_cast<HICON>(LoadImageW(
      module, MAKEINTRESOURCEW(IDI_APP_ICON + index), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON),
      LR_DEFAULTCOLOR));
  return ApplyIcons(big_icon, small_icon);
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
  return ApplyIcons(big_icon, small_icon);
}

// Title bar, Alt+Tab and the running taskbar button (when not resolved to a
// shortcut) read the window icons; the class icons back them up for windows
// Windows creates from the class (e.g. after DPI changes).
bool FlutterWindow::ApplyIcons(HICON big_icon, HICON small_icon) {
  if (!big_icon || !small_icon) {
    if (big_icon) DestroyIcon(big_icon);
    if (small_icon) DestroyIcon(small_icon);
    return false;
  }
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    DestroyIcon(big_icon);
    DestroyIcon(small_icon);
    return false;
  }
  SendMessage(hwnd, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(big_icon));
  SendMessage(hwnd, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(small_icon));
  SetClassLongPtr(hwnd, GCLP_HICON, reinterpret_cast<LONG_PTR>(big_icon));
  SetClassLongPtr(hwnd, GCLP_HICONSM, reinterpret_cast<LONG_PTR>(small_icon));
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
    RemoveNotifyIcon();
    DestroyWindow(hwnd);
    return 0;
  }
  if (message == WM_TIMER && wparam == kNotifyTimerId) {
    RemoveNotifyIcon();
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
  if (message == WM_SIZE && wparam == SIZE_MINIMIZED) {
    // Dart hides the window to the tray when "minimise to tray" is on.
    Notify("minimized");
  }
  if (message == WM_SIZE && wparam != SIZE_MINIMIZED) {
    // The custom caption's maximize / restore button follows the window.
    const bool maximized = wparam == SIZE_MAXIMIZED;
    if (maximized != was_maximized_) {
      was_maximized_ = maximized;
      Notify(maximized ? "maximized" : "unmaximized");
      // Maximized windows are square; restored ones round again (Windows 11).
      frame_.UpdateCorners(maximized);
    }
  }
  if (std::optional<LRESULT> handled =
          frame_.HandleMessage(hwnd, message, wparam, lparam)) {
    return *handled;
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
    case WM_SIZE:
      // The view sits below the frame's top border strip (Windows 10).
      frame_.PlaceView();
      return 0;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
