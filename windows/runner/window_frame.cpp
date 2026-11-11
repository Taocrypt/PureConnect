#include "window_frame.h"

#include <dwmapi.h>

namespace {

#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#ifndef DWMWA_SYSTEMBACKDROP_TYPE
#define DWMWA_SYSTEMBACKDROP_TYPE 38
#endif
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif
#ifndef DWMWA_MICA_EFFECT
#define DWMWA_MICA_EFFECT 1029
#endif
// The pre-20H1 value of the same attribute.
#define DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1 19

constexpr int kSystemBackdropBuild = 22621;

enum WindowCornerPreference {
  kDwmwcpDoNotRound = 1,
  kDwmwcpRound = 2,
};

enum SystemBackdropType {
  kDwmsbtNone = 1,
  kDwmsbtMainWindow = 2,
};

enum AccentState {
  kAccentDisabled = 0,
  kAccentEnableBlurBehind = 3,
};

struct AccentPolicy {
  int accent_state;
  int accent_flags;
  int gradient_color;
  int animation_id;
};

struct WindowCompositionAttributeData {
  int attribute;
  PVOID data;
  SIZE_T size_in_bytes;
};

using SetWindowCompositionAttributeFn =
    BOOL(WINAPI*)(HWND, WindowCompositionAttributeData*);

SetWindowCompositionAttributeFn GetSetWindowCompositionAttribute() {
  static const SetWindowCompositionAttributeFn function = [] {
    const HMODULE user32 = ::GetModuleHandleW(L"user32.dll");
    return user32 == nullptr
               ? nullptr
               : reinterpret_cast<SetWindowCompositionAttributeFn>(
                     ::GetProcAddress(user32, "SetWindowCompositionAttribute"));
  }();
  return function;
}

using RtlGetVersionFn = LONG(WINAPI*)(OSVERSIONINFOW*);

int QueryBuildNumber() {
  const HMODULE ntdll = ::GetModuleHandleW(L"ntdll.dll");
  if (ntdll == nullptr) return 0;
  const auto rtl_get_version = reinterpret_cast<RtlGetVersionFn>(
      ::GetProcAddress(ntdll, "RtlGetVersion"));
  if (rtl_get_version == nullptr) return 0;
  OSVERSIONINFOW info{};
  info.dwOSVersionInfoSize = sizeof(info);
  if (rtl_get_version(&info) != 0) return 0;
  return static_cast<int>(info.dwBuildNumber);
}

// SetWindowCompositionAttribute takes its color as ABGR.
uint32_t ToAccentColor(uint32_t argb) {
  const uint32_t a = (argb >> 24) & 0xFF;
  const uint32_t r = (argb >> 16) & 0xFF;
  const uint32_t g = (argb >> 8) & 0xFF;
  const uint32_t b = argb & 0xFF;
  return (a << 24) | (b << 16) | (g << 8) | r;
}

}  // namespace

int WindowFrame::BuildNumber() {
  static const int build = QueryBuildNumber();
  return build;
}

bool WindowFrame::IsWindows11OrGreater() { return BuildNumber() >= 22000; }

void WindowFrame::Attach(HWND hwnd, HWND view) {
  hwnd_ = hwnd;
  view_ = view;
  Apply();
}

bool WindowFrame::IsMaximized() const {
  if (hwnd_ == nullptr) return false;
  WINDOWPLACEMENT placement{sizeof(WINDOWPLACEMENT)};
  ::GetWindowPlacement(hwnd_, &placement);
  return placement.showCmd == SW_MAXIMIZE;
}

// Windows 10 draws the top border only inside a frame extended over the
// whole caption, so the frame is extended there while no effect is on.
bool WindowFrame::ExtendsTopFrame() const {
  return effect_ == FrameEffect::kNone && !IsWindows11OrGreater();
}

// Rows kept clear above the view and painted transparent (Windows 10).
int WindowFrame::TopBorderHeight() const {
  if (hwnd_ == nullptr || !ExtendsTopFrame() || ::IsZoomed(hwnd_)) return 0;
  const bool sizable = (::GetWindowLongPtrW(hwnd_, GWL_STYLE) & WS_THICKFRAME) != 0;
  return sizable ? 1 : 0;
}

bool WindowFrame::SetBlur(bool enabled, uint32_t tint_argb, bool dark) {
  FrameEffect effect = FrameEffect::kNone;
  if (enabled) {
    // Windows 10's acrylic makes the window trail the pointer while dragged,
    // so Windows 10 takes the plain accent blur (as FlClash does).
    if (IsWindows11OrGreater()) {
      effect = FrameEffect::kMica;
    } else if (GetSetWindowCompositionAttribute() != nullptr) {
      effect = FrameEffect::kBlur;
    }
  }
  effect_ = effect;
  tint_ = tint_argb;
  dark_ = dark;
  Apply();
  PlaceView();
  return effect != FrameEffect::kNone;
}

void WindowFrame::Apply() const {
  HWND hwnd = hwnd_;
  if (hwnd == nullptr) return;

  int accent_state = kAccentDisabled;
  uint32_t accent_color = 0;
  int backdrop_type = kDwmsbtNone;
  if (effect_ == FrameEffect::kBlur) {
    accent_state = kAccentEnableBlurBehind;
    accent_color = ToAccentColor(tint_);
  } else if (effect_ == FrameEffect::kMica) {
    backdrop_type = kDwmsbtMainWindow;
  }

  // Windows fills an extended frame opaque, which would cover an accent effect.
  MARGINS margins{};
  if (effect_ == FrameEffect::kMica) {
    margins = {-1, -1, -1, -1};
  } else if (ExtendsTopFrame()) {
    RECT frame{};
    ::AdjustWindowRectExForDpi(&frame, WS_OVERLAPPEDWINDOW, FALSE, 0,
                               ::GetDpiForWindow(hwnd));
    margins.cyTopHeight = -frame.top;
  }
  ::DwmExtendFrameIntoClientArea(hwnd, &margins);

  const int corner_preference = IsMaximized() ? kDwmwcpDoNotRound : kDwmwcpRound;
  ::DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE,
                          &corner_preference, sizeof(corner_preference));

  if (BuildNumber() >= kSystemBackdropBuild) {
    ::DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, &backdrop_type,
                            sizeof(backdrop_type));
  } else if (IsWindows11OrGreater()) {
    const BOOL mica = effect_ == FrameEffect::kMica ? TRUE : FALSE;
    ::DwmSetWindowAttribute(hwnd, DWMWA_MICA_EFFECT, &mica, sizeof(mica));
  }

  // The system backdrops pick their light or dark material from this
  // attribute, which also colours the frame border.
  if (dark_.has_value() && BuildNumber() >= 17763) {
    const BOOL dark = *dark_ ? TRUE : FALSE;
    const DWORD attribute = BuildNumber() >= 18985
                                ? DWMWA_USE_IMMERSIVE_DARK_MODE
                                : DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1;
    ::DwmSetWindowAttribute(hwnd, attribute, &dark, sizeof(dark));
  }

  // With Mica the frame covers the whole window and DWM would draw the
  // caption buttons over it; clearing WS_SYSMENU (which gates the minimize
  // and maximize boxes) hides them.
  LONG_PTR style_bits = ::GetWindowLongPtrW(hwnd, GWL_STYLE);
  style_bits = effect_ == FrameEffect::kMica ? (style_bits & ~WS_SYSMENU)
                                             : (style_bits | WS_SYSMENU);
  ::SetWindowLongPtrW(hwnd, GWL_STYLE, style_bits);

  if (const auto set_composition_attribute = GetSetWindowCompositionAttribute();
      set_composition_attribute != nullptr) {
    AccentPolicy policy{accent_state, 2, static_cast<int>(accent_color), 0};
    WindowCompositionAttributeData data{19, &policy, sizeof(policy)};
    set_composition_attribute(hwnd, &data);
  }

  ::SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                 SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_NOMOVE | SWP_NOSIZE |
                     SWP_NOACTIVATE | SWP_FRAMECHANGED);
}

void WindowFrame::UpdateCorners(bool maximized) const {
  if (hwnd_ == nullptr) return;
  const int corner_preference = maximized ? kDwmwcpDoNotRound : kDwmwcpRound;
  ::DwmSetWindowAttribute(hwnd_, DWMWA_WINDOW_CORNER_PREFERENCE,
                          &corner_preference, sizeof(corner_preference));
}

void WindowFrame::PlaceView() const {
  // Minimizing changes the frame too; fitting the view to what is left would
  // lay the app out at phone width, which a restore then shows.
  if (hwnd_ == nullptr || view_ == nullptr || ::IsIconic(hwnd_)) return;
  RECT client{};
  ::GetClientRect(hwnd_, &client);
  const LONG border = TopBorderHeight();
  const LONG height = client.bottom > border ? client.bottom - border : 0;
  ::MoveWindow(view_, 0, border, client.right, height, TRUE);
}

std::optional<LRESULT> WindowFrame::HandleMessage(HWND hwnd, UINT message,
                                                  WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_NCCALCSIZE: {
      if (!wparam) return std::nullopt;
      // The insets come from the window's styles; maximized windows hang
      // past the monitor edge by one frame width.
      RECT frame{};
      ::AdjustWindowRectExForDpi(
          &frame, static_cast<DWORD>(::GetWindowLongPtrW(hwnd, GWL_STYLE)), FALSE,
          static_cast<DWORD>(::GetWindowLongPtrW(hwnd, GWL_EXSTYLE)),
          ::GetDpiForWindow(hwnd));
      RECT* rect = &reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam)->rgrc[0];
      rect->left -= frame.left;
      rect->right -= frame.right;
      rect->bottom -= frame.bottom;
      // Windows 11 draws the top border only into a non-client strip; Windows
      // 10 must get none (DWM draws the whole caption over a shorter strip).
      rect->top += ::IsZoomed(hwnd) ? frame.bottom : (IsWindows11OrGreater() ? 1 : 0);
      return 0;
    }
    case WM_NCACTIVATE:
      // Nothing of the system caption is left to repaint.
      return TRUE;
    case WM_WINDOWPOSCHANGED: {
      const auto* pos = reinterpret_cast<const WINDOWPOS*>(lparam);
      if ((pos->flags & SWP_FRAMECHANGED) != 0) PlaceView();
      return std::nullopt;
    }
    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      const double scale = ::GetDpiForWindow(hwnd) / 96.0;
      info->ptMinTrackSize.x = static_cast<LONG>(380 * scale);
      info->ptMinTrackSize.y = static_cast<LONG>(400 * scale);
      return 0;
    }
    case WM_PAINT: {
      const LONG border = TopBorderHeight();
      if (border == 0) return std::nullopt;
      PAINTSTRUCT paint{};
      const HDC dc = ::BeginPaint(hwnd, &paint);
      RECT strip = paint.rcPaint;
      if (strip.bottom > border) strip.bottom = border;
      // DWM shows the extended frame where the client is painted black.
      if (strip.top < strip.bottom) {
        ::FillRect(dc, &strip, static_cast<HBRUSH>(::GetStockObject(BLACK_BRUSH)));
      }
      ::EndPaint(hwnd, &paint);
      return 0;
    }
    case WM_NCHITTEST: {
      const LONG border = TopBorderHeight();
      if (border == 0) return std::nullopt;
      const LRESULT hit = ::DefWindowProcW(hwnd, message, wparam, lparam);
      const POINT point{static_cast<short>(LOWORD(lparam)),
                        static_cast<short>(HIWORD(lparam))};
      RECT window{};
      ::GetWindowRect(hwnd, &window);
      if (hit != HTCLIENT || point.y >= window.top + border) return hit;
      RECT frame{};
      ::AdjustWindowRectExForDpi(&frame, WS_OVERLAPPEDWINDOW, FALSE, 0,
                                 ::GetDpiForWindow(hwnd));
      const LONG corner = -frame.left * 2;
      if (point.x < window.left + corner) return HTTOPLEFT;
      if (point.x >= window.right - corner) return HTTOPRIGHT;
      return HTTOP;
    }
  }
  return std::nullopt;
}
