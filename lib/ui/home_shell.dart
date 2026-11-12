import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../core/backend.dart';
import '../core/desktop_shell.dart';
import '../core/desktop_window.dart';
import '../core/errors.dart';
import '../core/protocol.dart';
import '../core/system_proxy.dart';
import '../l10n/strings.dart';
import '../models/profile.dart';
import '../models/settings.dart';
import '../state/providers.dart';
import 'kit/app_glyphs.dart';
import 'kit/common.dart';
import 'kit/dashboard_kit.dart';
import 'widgets/update_dialog.dart';
import 'pages/dashboard_page.dart';
import 'pages/disclaimer_page.dart';
import 'pages/logs_page.dart';
import 'pages/profiles_page.dart';
import 'pages/resources_page.dart';
import 'pages/settings_page.dart';
import 'widgets/challenge_dialogs.dart';
import 'widgets/connect_prompts.dart';
import 'tour/guide_tour.dart';
import 'window_frame.dart';

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
    GuideTour.instance.showTab = (tab) {
      if (!mounted) return;
      ref.read(currentTabProvider.notifier).go(switch (tab) {
        GuideTab.profiles => AppTab.profiles,
        GuideTab.dashboard => AppTab.dashboard,
      });
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _surfaceCrashLog();
      if (!mounted) return;
      _attachDesktop();
      _startup();
      // Quietly look for a new release every launch: a forced update is always
      // shown, a normal one only with "check for updates on launch" on.
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) checkForUpdate(context, ref);
      });
    });
  }

  /// Launch-time actions: the setup guide on a first run without profiles,
  /// then connecting when "connect on launch" is on or the app was started
  /// with `--connect`.
  Future<void> _startup() async {
    final args = await DesktopWindow.launchArgs();
    if (!mounted) return;
    // The disclaimer comes first, once per disclaimer version (also for
    // users updating from a version without it). Declining leaves the app.
    if (needsDisclaimer(ref.read(settingsProvider).disclaimerAccepted)) {
      if (DesktopWindow.isDesktop) await DesktopWindow.show();
      if (!mounted) return;
      final agreed = await requestDisclaimerConsent(context);
      if (!agreed) {
        await exitAfterDecline();
        return;
      }
      ref.read(settingsProvider.notifier).update((s) => s.disclaimerAccepted = disclaimerVersion);
      if (!mounted) return;
    }
    final settings = ref.read(settingsProvider);
    if (ref.read(profilesProvider).isEmpty && !settings.setupGuideShown && !args.contains('--hidden')) {
      ref.read(settingsProvider.notifier).update((s) => s.setupGuideShown = true);
      GuideTour.instance.start();
    }
    final connect = settings.autoConnect || args.contains('--connect');
    if (connect && ref.read(profilesProvider).isNotEmpty && !ref.read(coreProvider).isActive) {
      await toggleConnection(context, ref);
    }
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

    final settings = ref.watch(settingsProvider.select((s) => (s.floatingNavBar, s.tabAnimation)));
    final floating = settings.$1;
    final body = TabStack(
      index: AppTab.values.indexOf(current),
      animate: mobile,
      fade: settings.$2 == 'fade',
      children: [for (final t in AppTab.values) KeyedSubtree(key: ValueKey(t), child: _page(t))],
    );

    if (mobile) {
      void select(int i) => ref.read(currentTabProvider.notifier).go(tabs[i]);
      return Surface(
        color: SurfaceLevel.page.colorOf(colorScheme),
        child: Column(children: [
          Expanded(
            child: Stack(children: [
              Positioned.fill(
                child: DockScope(
                  floating: floating,
                  child: floating ? body : MediaQuery.removePadding(context: context, removeBottom: true, child: body),
                ),
              ),
              if (floating)
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
                    onSelected: select,
                  ),
                ),
            ]),
          ),
          // FlClash's docked bar, where the floating dock is turned off.
          if (!floating)
            NavigationBar(
              destinations: [
                for (final (i, t) in tabs.indexed)
                  NavigationDestination(
                    icon: AnimatedGlyph(glyph: _dest(t).$1, filled: i == index),
                    label: _dest(t).$2,
                  ),
              ],
              selectedIndex: index,
              onDestinationSelected: select,
            ),
        ]),
      );
    }

    // Sidebar blur: the window's backdrop material shows through the rail
    // (half its own colour over it); the pages keep their opaque surface.
    final backdropOpacity = ref.watch(windowBlurProvider);
    final page = SurfaceLevel.page.colorOf(colorScheme);
    final chrome = colorScheme.chromeSurface;
    return ColoredBox(
      color: backdropOpacity != null ? const Color(0x00000000) : page,
      child: Row(children: [
        Surface(
          color: backdropOpacity != null ? chrome.withValues(alpha: backdropOpacity) : chrome,
          shape: BorderDirectional(end: Divider.createBorderSide(context)),
          child: NavigationSidebar(
            destinations: [
              for (final t in tabs) SidebarDestination(glyph: _dest(t).$1, label: _dest(t).$2),
            ],
            selectedIndex: index,
            expanded: ref.watch(sidebarExpandedProvider),
            windowControls: windowControlsOverPage(isMobileView: false),
            onToggle: ref.read(sidebarExpandedProvider.notifier).toggle,
            onSelected: (i) => ref.read(currentTabProvider.notifier).go(tabs[i]),
          ),
        ),
        Expanded(child: ClipRect(child: ColoredBox(color: page, child: body))),
      ]),
    );
  }
}

/// The tabs' pages, all kept alive. On the phone a tab switch slides the
/// pages across or cross-fades them in place (FlClash's tab animation);
/// elsewhere it switches at once.
class TabStack extends StatefulWidget {
  const TabStack({super.key, required this.index, required this.children, this.animate = true, this.fade = false});

  final int index;
  final List<Widget> children;
  final bool animate;
  final bool fade;

  @override
  State<TabStack> createState() => _TabStackState();
}

class _TabStackState extends State<TabStack> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, value: 1);
  int? _previous;

  @override
  void didUpdateWidget(TabStack old) {
    super.didUpdateWidget(old);
    if (old.index == widget.index) return;
    if (!widget.animate) {
      _controller.value = 1;
      _previous = null;
      return;
    }
    _previous = old.index;
    _controller.duration = widget.fade ? fadeTabDuration : kTabScrollDuration;
    final target = widget.index;
    _controller.forward(from: 0).whenCompleteOrCancel(() {
      if (mounted && widget.index == target) setState(() => _previous = null);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final previous = _previous;
        final t = (widget.fade ? fadeTabCurve : Curves.easeOut).transform(_controller.value);
        final dir = previous == null ? 0.0 : (widget.index > previous ? 1.0 : -1.0);
        return Stack(fit: StackFit.expand, children: [
          for (final (i, child) in widget.children.indexed)
            _slot(
              visible: i == widget.index || i == previous,
              // Incoming page from the side it lies on, outgoing to the other.
              dx: widget.fade || previous == null
                  ? 0
                  : (i == widget.index ? (1 - t) * dir : -t * dir),
              opacity: !widget.fade || previous == null ? 1 : (i == widget.index ? t : 1 - t),
              child: child,
            ),
        ]);
      },
    );
  }

  Widget _slot({required bool visible, required double dx, required double opacity, required Widget child}) => Offstage(
        offstage: !visible,
        child: TickerMode(
          enabled: visible,
          child: FractionalTranslation(
            translation: Offset(dx, 0),
            child: Opacity(opacity: opacity.clamp(0.0, 1.0), child: child),
          ),
        ),
      );
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

/// Starts or stops the core. Before connecting: asks for a user name /
/// password (or SMS phone number) the profile does not store, confirms
/// replacing another app's system proxy, and asks for the admin password when
/// the desktop TUN mode needs it (macOS, or Linux without pkexec).
Future<void> toggleConnection(BuildContext context, WidgetRef ref) async {
  final ctl = ref.read(coreProvider.notifier);
  if (ref.read(coreProvider).isActive) {
    await ctl.disconnect();
    return;
  }
  final s = ref.read(settingsProvider);
  Profile? oneTime;
  final profile = ref.read(selectedProfileProvider);
  if (profile != null) {
    final missing = missingLogin(profile);
    if (missing != null) {
      final a = await askLogin(context, profile, missing);
      if (a == null || !context.mounted) return;
      final p = profile.copy();
      if (missing == 'phone') {
        p.phone = a.phone;
      } else {
        p.username = a.username;
        p.password = a.password;
      }
      if (a.remember) {
        ref.read(profilesProvider.notifier).upsert(p);
      } else {
        oneTime = p;
      }
    }
  }
  if (s.setsSystemProxy(s.trafficMode, android: Platform.isAndroid) &&
      SystemProxy.supported &&
      s.warnProxyOverride) {
    final other = await SystemProxy.foreignProxy(ref.read(dataDirProvider));
    if (other != null) {
      if (!context.mounted) return;
      final dontAsk = await confirmProxyOverride(context, other);
      if (dontAsk == null) return;
      if (dontAsk) ref.read(settingsProvider.notifier).update((x) => x.warnProxyOverride = false);
    }
  }
  String? password;
  final needsPassword = s.trafficMode == TrafficMode.tun &&
      await DesktopCoreBackend.needsSudoPassword();
  if (needsPassword) {
    if (!context.mounted) return;
    password = await askPassword(context, context.tr('sudo_title'), context.tr('sudo_hint'));
    if (password == null) return;
  }
  await ctl.connect(sudoPassword: password, profileOverride: oneTime);
}
