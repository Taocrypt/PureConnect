// Immersive window frame, ported from FlClash's window plugin
// (plugins/window/windows/window_style.cpp and window_controller.cpp,
// https://github.com/chen08209/FlClash, MIT): the caption bar is removed
// (WM_NCCALCSIZE) while the frame, border, shadow and resize edges stay;
// Windows 11 rounds the corners; the sidebar blur shows Mica (Windows 11)
// or the accent blur (Windows 10) behind a translucent app.
#ifndef RUNNER_WINDOW_FRAME_H_
#define RUNNER_WINDOW_FRAME_H_

#include <windows.h>

#include <cstdint>
#include <optional>

enum class FrameEffect { kNone, kBlur, kMica };

class WindowFrame {
 public:
  // Applies the hidden caption to |hwnd| (call once after creation).
  void Attach(HWND hwnd, HWND view);
  void SetView(HWND view) { view_ = view; }

  // Sidebar blur. Returns whether an effect is drawn.
  bool SetBlur(bool enabled, uint32_t tint_argb, bool dark);

  // Handles the frame's messages; nullopt lets the message go on.
  std::optional<LRESULT> HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                                       LPARAM lparam);

  // Fits the Flutter view to the client area below the top border strip.
  void PlaceView() const;

  bool IsMaximized() const;

  // Windows 11: square corners while maximized, round otherwise.
  void UpdateCorners(bool maximized) const;

  static int BuildNumber();
  static bool IsWindows11OrGreater();

 private:
  void Apply() const;
  bool ExtendsTopFrame() const;
  int TopBorderHeight() const;

  HWND hwnd_ = nullptr;
  HWND view_ = nullptr;
  FrameEffect effect_ = FrameEffect::kNone;
  uint32_t tint_ = 0;
  std::optional<bool> dark_;
};

#endif  // RUNNER_WINDOW_FRAME_H_
