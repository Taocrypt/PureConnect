import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray/tray.dart';

import '../l10n/strings.dart';
import '../models/settings.dart';
import '../state/providers.dart';
import 'app_icon.dart';
import 'desktop_window.dart';
import 'notify.dart';
import 'protocol.dart';

/// Desktop window + tray behaviour (Windows / macOS / Linux): the tray (menu
/// bar) icon with status, connect/disconnect, traffic mode and profile
/// switching; the close button hiding to the tray; and a clean quit that
/// stops the core and restores the system proxy before the process ends.
///
/// Android has the equivalent in its foreground notification.
class DesktopShell {
  DesktopShell._();
  static final instance = DesktopShell._();

  BuildContext? _context;
  WidgetRef? _ref;
  StreamSubscription<TrayEvent>? _traySub;
  bool _trayShown = false;
  bool _quitting = false;
  bool _hiddenHintShown = false;

  /// Actions that need the UI (password prompt, toasts); set by HomeShell.
  Future<void> Function()? onToggleConnection;
  Future<void> Function(TrafficMode mode)? onSwitchMode;
  Future<void> Function(String profileId)? onSwitchProfile;

  bool get trayAvailable => _trayShown;

  Future<void> attach(BuildContext context, WidgetRef ref) async {
    if (!DesktopWindow.isDesktop) return;
    _context = context;
    _ref = ref;
    DesktopWindow.channel.setMethodCallHandler(_onNative);
    await DesktopWindow.setPreventClose(true);
    if (Platform.isMacOS && ref.read(settingsProvider).hideDockIcon) {
      await DesktopWindow.setDockIconVisible(false);
    }
    _traySub ??= Tray.instance.events.listen(handleTrayEvent);
    await refreshTray();
  }

  /// Tray clicks. The Windows and macOS tray plugin never pops its menu by
  /// itself: a right click (and on macOS any click) only reports
  /// [TrayMenuRequested], and the app has to ask for the menu. Linux
  /// (AppIndicator) shows the menu natively and sends no such event.
  @visibleForTesting
  void handleTrayEvent(TrayEvent e, {Future<void> Function()? openMenu}) {
    switch (e) {
      case TrayIconActivated():
        DesktopWindow.show();
      case TrayMenuRequested():
        unawaited((openMenu ?? Tray.instance.openMenu)().catchError((_) {}));
      case TrayMenuItemSelected():
        break;
    }
  }

  Future<dynamic> _onNative(MethodCall call) async {
    switch (call.method) {
      case 'close':
        final ref = _ref;
        if (ref != null && ref.read(settingsProvider).closeToTray && _trayShown) {
          await _hideToTray();
        } else {
          await quit();
        }
      case 'minimized':
        final ref = _ref;
        if (ref != null && ref.read(settingsProvider).minimizeToTray && _trayShown) {
          await _hideToTray();
        }
      case 'quitRequested':
        await quit();
      case 'activate':
        break;
    }
    return null;
  }

  /// Hides the window; the first time in a run, says where it went.
  Future<void> _hideToTray() async {
    await DesktopWindow.hide();
    final ref = _ref;
    if (_hiddenHintShown || ref == null || !ref.read(settingsProvider).notifications) return;
    _hiddenHintShown = true;
    final s = _s;
    await SystemNotify.show('PureConnect', s.t('notify_hidden_to_tray'));
  }

  S get _s {
    final c = _context;
    if (c != null && c.mounted) return S.of(c);
    return S('en');
  }

  /// Rebuilds the tray from the current state (cheap when unchanged).
  Future<void> refreshTray() async {
    final ref = _ref;
    if (ref == null || _quitting || !DesktopWindow.isDesktop) return;
    final s = _s;
    final core = ref.read(coreProvider);
    final settings = ref.read(settingsProvider);
    final profiles = ref.read(profilesProvider);
    final selected = ref.read(selectedProfileProvider);
    final status = switch (core.state) {
      CoreState.connected => s.t('connected'),
      CoreState.starting || CoreState.connecting => s.t('connecting'),
      _ => s.t('disconnected'),
    };
    final name = core.isActive ? core.profileName : (selected?.name ?? '');
    final line = name.isEmpty ? status : '$status · $name';
    final modes = [
      (TrafficMode.proxy, s.t('mode_proxy')),
      (TrafficMode.systemProxy, s.t('mode_system_proxy')),
      (TrafficMode.tun, s.t('mode_tun')),
    ];
    final icon = settings.appIcon;
    final spec = TraySpec(
      icon: TrayIcon.asset(Platform.isWindows ? 'assets/icon/$icon.ico' : appIconPreview(icon)),
      toolTip: 'PureConnect · $line',
      menu: [
        TrayMenuAction(label: line, enabled: false),
        const TrayMenuSeparator(),
        TrayMenuAction(label: s.t('tray_show'), onSelected: DesktopWindow.show),
        TrayMenuAction(
          label: core.isActive ? s.t('disconnect') : s.t('connect'),
          enabled: profiles.isNotEmpty && core.state != CoreState.stopping,
          onSelected: () => onToggleConnection?.call(),
        ),
        TrayMenuSubmenu(label: s.t('traffic_mode'), items: [
          for (final m in modes)
            TrayMenuCheckbox(
              label: m.$2,
              checked: settings.trafficMode == m.$1,
              onSelected: () => onSwitchMode?.call(m.$1),
            ),
        ]),
        if (profiles.isNotEmpty)
          TrayMenuSubmenu(label: s.t('profiles'), items: [
            for (final p in profiles)
              TrayMenuCheckbox(
                label: p.name.isEmpty ? p.effectiveServer : p.name,
                checked: p.id == selected?.id,
                onSelected: () => onSwitchProfile?.call(p.id),
              ),
          ]),
        const TrayMenuSeparator(),
        TrayMenuAction(label: s.t('tray_quit'), onSelected: quit),
      ],
    );
    try {
      await Tray.instance.show(spec);
      _trayShown = true;
    } catch (_) {
      // No tray host (e.g. GNOME without the AppIndicator extension): the
      // close button then quits instead of hiding.
      _trayShown = false;
    }
  }

  /// Stops the core, restores the system proxy, removes the tray, exits.
  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    final ref = _ref;
    if (ref != null) await ref.read(coreProvider.notifier).shutdown();
    try {
      await Tray.instance.hide().timeout(const Duration(seconds: 2));
    } catch (_) {}
    await DesktopWindow.quit();
  }
}
