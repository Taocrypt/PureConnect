// Immersive window frame, after FlClash's WindowManager / WindowHeader
// (https://github.com/chen08209/FlClash, GPL-3.0): the runners hide the
// system title bar (Windows, Linux) or make it transparent over the content
// (macOS 11+), and the app draws its own caption with a drag area,
// double-click to maximize and the minimize / maximize / close buttons.
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../core/desktop_shell.dart';
import '../core/desktop_window.dart';
import '../l10n/strings.dart';
import '../state/providers.dart';
import 'kit/app_glyphs.dart';

/// Windows 11 draws its caption buttons 46 wide over a 32 tall title bar;
/// macOS' title bar is 28 tall.
const captionButtonWidth = 46.0;
double get windowHeaderHeight => Platform.isMacOS ? 28 : 32;

/// Measured on macOS, the traffic lights span 9 to 69 from the left edge of
/// the hidden 32 tall title bar.
const macOSTrafficLightsArea = Size(78, 32);

/// Whether the app draws a caption strip above everything: always with the
/// custom frame on Windows / Linux; on macOS only in the phone layout, where
/// the traffic lights have no sidebar to sit over.
bool showsWindowHeader({required bool isMobileView}) {
  if (!DesktopWindow.isDesktop || !DesktopWindow.customFrame) return false;
  return !Platform.isMacOS || isMobileView;
}

/// The area the macOS traffic lights take over the sidebar (wide layout).
Size windowControlsOverPage({required bool isMobileView}) {
  if (isMobileView || !Platform.isMacOS || !DesktopWindow.customFrame) return Size.zero;
  return macOSTrafficLightsArea;
}

/// How opaque the sidebar keeps its colour over the window's backdrop
/// material (sidebar blur), or null while no material is drawn.
final windowBlurProvider = NotifierProvider<WindowBlurNotifier, double?>(WindowBlurNotifier.new);

class WindowBlurNotifier extends Notifier<double?> {
  @override
  double? build() => null;
  void set(double? v) => state = v;
}

/// Keeps the window's backdrop material in step with the sidebar-blur
/// setting and the theme, and lays the caption over the app when the frame
/// is the app's own.
class WindowFrame extends ConsumerStatefulWidget {
  const WindowFrame({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<WindowFrame> createState() => _WindowFrameState();
}

class _WindowFrameState extends ConsumerState<WindowFrame> {
  (bool, bool, int)? _applied;
  int _revision = 0;

  void _syncBlur(bool enabled, Brightness brightness, Color tint) {
    final request = (enabled, brightness == Brightness.dark, tint.toARGB32());
    if (request == _applied) return;
    // The first frame never asks to turn off what was never on.
    if (_applied == null && !enabled) {
      _applied = request;
      return;
    }
    _applied = request;
    final revision = ++_revision;
    // Windows 10's accent blur draws nothing without a tint; the sidebar's
    // own colour stays half over every material.
    final argb = tint.withValues(alpha: 0.5).toARGB32();
    unawaited(DesktopWindow.setBlur(enabled: enabled, dark: request.$2, tint: argb).then((opacity) {
      if (mounted && revision == _revision) ref.read(windowBlurProvider.notifier).set(opacity);
    }));
  }

  @override
  Widget build(BuildContext context) {
    if (!DesktopWindow.isDesktop) return widget.child;
    final enabled = ref.watch(settingsProvider.select((s) => s.sidebarBlur));
    final scheme = context.colorScheme;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncBlur(enabled, scheme.brightness, scheme.surfaceContainer);
    });
    final mobile = ViewScope.isMobileOf(context);
    if (!showsWindowHeader(isMobileView: mobile)) return widget.child;
    final height = windowHeaderHeight;
    return Overlay.wrap(
      child: Stack(children: [
        Column(children: [
          SizedBox(height: height),
          Expanded(
            child: MediaQuery.removePadding(context: context, removeTop: true, child: widget.child),
          ),
        ]),
        Positioned(top: 0, left: 0, right: 0, child: WindowHeaderBar(height: height)),
      ]),
    );
  }
}

class WindowHeaderBar extends ConsumerWidget {
  const WindowHeaderBar({super.key, required this.height});

  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = context.colorScheme;
    final mobile = ViewScope.isMobileOf(context);
    final backdropOpacity = mobile ? null : ref.watch(windowBlurProvider);
    final fill = backdropOpacity != null
        ? colorScheme.chromeSurface.withValues(alpha: backdropOpacity)
        : colorScheme.chromeSurface;
    return Surface(
      color: const Color(0x00000000),
      shape: Border(bottom: Divider.createBorderSide(context)),
      child: SizedBox(
        height: height,
        child: Stack(alignment: AlignmentDirectional.center, children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => DesktopWindow.startDragging(),
              onDoubleTap: DesktopWindow.toggleMaximize,
              child: ColoredBox(color: fill),
            ),
          ),
          if (Platform.isMacOS)
            Positioned.fill(
              child: IgnorePointer(
                child: Center(child: Text('PureConnect', style: AppTextStyle.subheadline.of(context, emphasized: true))),
              ),
            ),
          if (!Platform.isMacOS)
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              child: ButtonTheme(
                // Caption buttons answer a pointer as the system's do.
                data: ButtonThemeData(
                  icon: ButtonStyle(
                    tapTargetSize: TapTargetSize.shrinkWrap,
                    minimumSize: Size(captionButtonWidth, height),
                    maximumSize: Size(captionButtonWidth, height),
                    padding: EdgeInsets.zero,
                    shape: AppShape.none,
                    foregroundColor: WidgetStatePropertyAll(colorScheme.onSurface),
                    overlayColor: WidgetStateProperty.fromMap({
                      WidgetState.pressed: colorScheme.onSurfaceVariant.withValues(alpha: 0.1),
                      WidgetState.hovered: colorScheme.onSurfaceVariant.withValues(alpha: 0.08),
                      WidgetState.focused: colorScheme.onSurfaceVariant.withValues(alpha: 0.1),
                    }),
                    pressLook: PressLook.none,
                  ),
                ),
                child: const WindowCaptionButtons(),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Pin, minimize, maximize / restore and close, as FlClash's caption.
class WindowCaptionButtons extends StatelessWidget {
  const WindowCaptionButtons({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = context.colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([DesktopWindow.maximized, DesktopWindow.alwaysOnTop]),
      builder: (context, _) {
        final maximized = DesktopWindow.maximized.value;
        final pinned = DesktopWindow.alwaysOnTop.value;
        return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AspectRatio(
            aspectRatio: 1,
            child: IconButton(
              tooltip: context.tr(pinned ? 'window_unpin' : 'window_pin'),
              style: const ButtonStyle(
                shape: AppShape.circle,
                minimumSize: Size.zero,
                maximumSize: Size.infinite,
                iconSize: 16,
              ),
              onPressed: () => DesktopWindow.setAlwaysOnTop(!pinned),
              icon: AnimatedGlyph(glyph: AppGlyphs.pin, filled: pinned),
            ),
          ),
          IconButton(
            tooltip: context.tr('window_minimize'),
            onPressed: DesktopWindow.minimize,
            icon: const CaptionIcon(CaptionGlyph.minimize),
          ),
          IconButton(
            tooltip: context.tr(maximized ? 'window_restore' : 'window_maximize'),
            onPressed: DesktopWindow.toggleMaximize,
            icon: CaptionIcon(maximized ? CaptionGlyph.restore : CaptionGlyph.maximize),
          ),
          IconButton(
            tooltip: context.tr('window_close'),
            style: ButtonStyle(
              backgroundColor: WidgetStateProperty.resolveWith((states) {
                final active = states.contains(WidgetState.hovered) || states.contains(WidgetState.pressed);
                return active ? cs.error : null;
              }),
              foregroundColor: WidgetStateProperty.resolveWith((states) {
                final active = states.contains(WidgetState.hovered) || states.contains(WidgetState.pressed);
                return active ? cs.onError : null;
              }),
              overlayColor: WidgetStateProperty.resolveWith((states) =>
                  states.contains(WidgetState.pressed) ? cs.onError.withValues(alpha: 0.12) : const Color(0x00000000)),
            ),
            onPressed: () => DesktopShell.instance.requestClose(),
            icon: const CaptionIcon(CaptionGlyph.close),
          ),
        ]);
      },
    );
  }
}
