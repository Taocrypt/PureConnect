#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <memory>
#include <optional>
#include <string>

#include "win32_window.h"
#include "window_frame.h"

// Registered window message a second launch posts to the running instance
// (see main.cpp) so it shows its window.
#define PURECONNECT_ACTIVATE_MESSAGE L"PureConnect.Activate"

// Previous WinINet proxy settings, restored on logoff/shutdown when the app
// set the system proxy and can't run Dart any more.
struct ProxySnapshot {
  DWORD enable = 0;
  std::wstring server;
  std::wstring bypass;
  std::wstring auto_config_url;
  bool has_auto_config_url = false;
};

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  // |start_hidden| keeps the window hidden after the first frame (launched at
  // login with --hidden); Dart shows it later via the window channel.
  FlutterWindow(const flutter::DartProject& project, bool start_hidden = false);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void HandleWindowCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  bool SetIconFromFile(const std::string& path);
  bool SetIconFromResource(int index);
  bool ApplyIcons(HICON big_icon, HICON small_icon);
  bool ShowNotification(const std::wstring& title, const std::wstring& body);
  void RemoveNotifyIcon();
  void ShowAndFocus();
  void Notify(const std::string& method);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // "pureconnect/window": icon, show/hide, close interception, quit and the
  // WinINet system proxy (see flutter_window.cpp).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> window_channel_;
  HICON big_icon_ = nullptr;
  bool notify_icon_added_ = false;
  HICON small_icon_ = nullptr;

  bool start_hidden_ = false;
  // Set by Dart once it handles "close": WM_CLOSE then goes to Dart, which
  // hides to the tray or cleans up and calls "quit".
  bool prevent_close_ = false;
  UINT activate_message_ = 0;
  // Immersive frame: hidden caption, rounded corners, sidebar blur.
  WindowFrame frame_;
  bool was_maximized_ = false;
  std::optional<ProxySnapshot> proxy_guard_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
