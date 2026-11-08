import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../core/backend.dart';
import '../core/desktop_shell.dart';
import '../core/desktop_window.dart';
import '../core/errors.dart';
import '../core/protocol.dart';
import '../l10n/strings.dart';
import '../models/settings.dart';
import '../state/providers.dart';
import 'kit/app_glyphs.dart';
import 'kit/common.dart';
import 'kit/dashboard_kit.dart';
import 'widgets/update_dialog.dart';
import 'pages/dashboard_page.dart';
import 'pages/logs_page.dart';
import 'pages/profiles_page.dart';
import 'pages/resources_page.dart';
import 'pages/settings_page.dart';
import 'widgets/challenge_dialogs.dart';

enum AppTab { dashboard, profiles, resources, logs, tools }

final currentTabProvider = NotifierProvider<_TabNotifier, AppTab>(_TabNotifier.new);

class _TabNotifier extends Notifier<AppTab> {
  @override
  AppTab build() => AppTab.dashboard;
  void go(AppTab t) => state = t;
}

final sidebarExpandedProvider = NotifierProvider<_Expanded, bool>(_Expanded.new);

class _Expanded extends Notifier<bool> {
  @override
  bool build() => true;
  void toggle() => state = !state;
}

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _surfaceCrashLog();
      if (!mounted) return;
      _attachDesktop();
      if (ref.read(settingsProvider).autoConnect && !ref.read(coreProvider).isActive) {
        toggleConnection(context, ref);
      }
      // Quietly look for a new release (setting, at most once a day).
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) checkForUpdate(context, ref);
      });
    });
  }

  /// Desktop: tray / menu-bar icon, close-to-tray and clean quit.
  void _attachDesktop() {
    if (!DesktopWindow.isDesktop) return;
    final shell = DesktopShell.instance;
    shell.onToggleConnection = () async {
      if (mounted) await toggleConnection(context, ref);
    };
    shell.onSwitchMode = (mode) async {
      if (mounted) await switchTrafficMode(context, ref, mode);
    };
    shell.onSwitchProfile = (id) async {
      if (mounted) await switchProfile(context, ref, id);
    };
    shell.attach(context, ref);
  }

  /// Moves UI errors recorded by main.dart's crash.log into the Logs page.
  void _surfaceCrashLog() {
    try {
      final f = File('${ref.read(dataDirProvider)}${Platform.pathSeparator}crash.log');
      if (!f.existsSync()) return;
      // Last entry only, from its start (the exception text and top frames).
      var text = f.readAsStringSync();
      final i = text.lastIndexOf('--- ');
      if (i > 0) text = text.substring(i);
      if (text.length > 4000) text = text.substring(0, 4000);
      f.renameSync('${f.path}.old');
      ref.read(logsProvider.notifier).add(LogEntry(DateTime.now(), 'error', 'UI error (previous run):\n$text'));
    } catch (_) {}
  }

  Future<void> _showChallenge(Challenge c) async {
    if (_dialogOpen) return;
    _dialogOpen = true;
    final answer = await showChallengeDialog(context, c);
    _dialogOpen = false;
    ref.read(coreProvider.notifier).answer(c, answer ?? const ChallengeAnswer.cancelled());
  }

  (Glyph, String) _dest(AppTab t) => switch (t) {
        AppTab.dashboard => (AppGlyphs.dashboard, context.tr('dashboard')),
        AppTab.profiles => (AppGlyphs.profiles, context.tr('profiles')),
        AppTab.resources => (AppGlyphs.resources, context.tr('resources')),
        AppTab.logs => (AppGlyphs.logs, context.tr('logs')),
        AppTab.tools => (AppGlyphs.tools, context.tr('tools')),
      };

  Widget _page(AppTab t) => switch (t) {
        AppTab.dashboard => const DashboardPage(),
        AppTab.profiles => const ProfilesPage(),
        AppTab.resources => const ResourcesPage(),
        AppTab.logs => const LogsPage(),
        AppTab.tools => const SettingsPage(),
      };

  @override
  Widget build(BuildContext context) {
    ref.watch(autoBackupProvider); // keeps WebDAV auto backup running
    DesktopCoreBackend.elevationPrompt = context.tr('elevation_prompt');
    if (DesktopWindow.isDesktop) {
      void tray(Object? _, Object? _) => DesktopShell.instance.refreshTray();
      ref.listen(coreProvider.select((c) => (c.state, c.profileName)), tray);
      ref.listen(settingsProvider.select((s) => (s.trafficMode, s.appIcon, s.selectedProfileId, s.locale)), tray);
      ref.listen(profilesProvider, tray);
    }
    ref.listen<ProxyHealth?>(proxyHealthProvider, (prev, next) {
      if (next == null || prev?.ok == next.ok) return;
      if (!next.ok) {
        showToast(context, context.tr('proxy_down', {'proxy': next.proxy}), level: BannerLevel.warning);
      } else if (prev != null) {
        showToast(context, context.tr('proxy_up'), level: BannerLevel.success);
      }
    });
    ref.listen<CoreStatus>(coreProvider, (prev, next) {
      if (next.challenges.isNotEmpty) _showChallenge(next.challenges.first);
      if (next.state == CoreState.error && prev?.state != CoreState.error && next.error != null) {
        showToast(context, humanizeError(context, next.error!),
            level: errorKey(next.error!) == 'cancelled' ? BannerLevel.info : BannerLevel.error);
      }
    });

    final mobile = isMobileLayout(context);
    // The phone dock keeps four tabs, as FlClash does; logs live under Tools.
    final tabs = mobile
        ? const [AppTab.dashboard, AppTab.profiles, AppTab.resources, AppTab.tools]
        : AppTab.values;
    var current = ref.watch(currentTabProvider);
    if (!tabs.contains(current)) current = AppTab.tools;
    final index = tabs.indexOf(current);
    final colorScheme = context.colorScheme;

    final body = IndexedStack(
      index: AppTab.values.indexOf(current),
      children: [for (final t in AppTab.values) KeyedSubtree(key: ValueKey(t), child: _page(t))],
    );

    if (mobile) {
      return Surface(
        color: SurfaceLevel.page.colorOf(colorScheme),
        child: Stack(children: [
          Positioned.fill(child: body),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: NavigationDock(
              destinations: [
                for (final t in tabs)
                  NavigationDockDestination(glyph: _dest(t).$1, label: _dest(t).$2),
              ],
              selectedIndex: index,
              onSelected: (i) => ref.read(currentTabProvider.notifier).go(tabs[i]),
            ),
          ),
        ]),
      );
    }

    return Surface(
      color: SurfaceLevel.page.colorOf(colorScheme),
      child: Row(children: [
        Surface(
          color: colorScheme.chromeSurface,
          shape: BorderDirectional(end: Divider.createBorderSide(context)),
          child: NavigationSidebar(
            destinations: [
              for (final t in tabs) SidebarDestination(glyph: _dest(t).$1, label: _dest(t).$2),
            ],
            selectedIndex: index,
            expanded: ref.watch(sidebarExpandedProvider),
            onToggle: ref.read(sidebarExpandedProvider.notifier).toggle,
            onSelected: (i) => ref.read(currentTabProvider.notifier).go(tabs[i]),
          ),
        ),
        Expanded(child: ClipRect(child: body)),
      ]),
    );
  }
}

/// Changes the traffic mode. While connected, tears the session down and
/// reconnects in the new mode.
Future<void> switchTrafficMode(BuildContext context, WidgetRef ref, TrafficMode mode) async {
  final settings = ref.read(settingsProvider.notifier);
  final core = ref.read(coreProvider);
  if (ref.read(settingsProvider).trafficMode == mode) return;
  if (!core.isActive) {
    settings.update((s) => s.trafficMode = mode);
    return;
  }
  if (core.isBusy && !core.isConnected && core.state != CoreState.connecting) return;
  String? password;
  final needsPassword = mode == TrafficMode.tun &&
      await DesktopCoreBackend.needsSudoPassword();
  if (needsPassword) {
    if (!context.mounted) return;
    password = await askPassword(context, context.tr('sudo_title'), context.tr('sudo_hint'));
    if (password == null) return;
  }
  if (context.mounted) showToast(context, context.tr('mode_switching'));
  final ctl = ref.read(coreProvider.notifier);
  await ctl.disconnect();
  await ctl.waitStopped();
  // Let the old process' trailing exit/stopped events drain first.
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  settings.update((s) => s.trafficMode = mode);
  await ctl.connect(sudoPassword: password);
}

/// Selects another profile. While connected, tears the session down and
/// reconnects with the new profile.
Future<void> switchProfile(BuildContext context, WidgetRef ref, String id) async {
  final settings = ref.read(settingsProvider.notifier);
  final core = ref.read(coreProvider);
  if (ref.read(settingsProvider).selectedProfileId == id) return;
  if (!core.isActive) {
    settings.update((s) => s.selectedProfileId = id);
    return;
  }
  if (core.isBusy && !core.isConnected && core.state != CoreState.connecting) return;
  String? password;
  final needsPassword = ref.read(settingsProvider).trafficMode == TrafficMode.tun &&
      await DesktopCoreBackend.needsSudoPassword();
  if (needsPassword) {
    if (!context.mounted) return;
    password = await askPassword(context, context.tr('sudo_title'), context.tr('sudo_hint'));
    if (password == null) return;
  }
  if (context.mounted) showToast(context, context.tr('profile_switching'));
  final ctl = ref.read(coreProvider.notifier);
  await ctl.disconnect();
  await ctl.waitStopped();
  // Let the old process' trailing exit/stopped events drain first.
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  settings.update((s) => s.selectedProfileId = id);
  await ctl.connect(sudoPassword: password);
}

/// Starts or stops the core; asks for the admin password first when the
/// desktop TUN mode needs it (macOS, or Linux without pkexec).
Future<void> toggleConnection(BuildContext context, WidgetRef ref) async {
  final ctl = ref.read(coreProvider.notifier);
  if (ref.read(coreProvider).isActive) {
    await ctl.disconnect();
    return;
  }
  String? password;
  final s = ref.read(settingsProvider);
  final needsPassword = s.trafficMode == TrafficMode.tun &&
      await DesktopCoreBackend.needsSudoPassword();
  if (needsPassword) {
    if (!context.mounted) return;
    password = await askPassword(context, context.tr('sudo_title'), context.tr('sudo_hint'));
    if (password == null) return;
  }
  await ctl.connect(sudoPassword: password);
}
