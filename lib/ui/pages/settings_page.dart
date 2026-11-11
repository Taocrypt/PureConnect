import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_icon.dart';
import '../../core/autostart.dart';
import '../../core/config_builder.dart' show debugDir;
import '../../core/extra_args.dart';
import '../../core/system_proxy.dart';
import '../../core/desktop_window.dart';
import '../../core/proxy_probe.dart';
import '../../core/updater.dart';
import '../../l10n/strings.dart';
import '../../models/settings.dart';
import '../../state/providers.dart';
import '../../core/apps.dart';
import '../widgets/app_list.dart';
import '../kit/app_glyphs.dart';
import '../kit/common.dart';
import '../kit/dashboard_kit.dart';
import 'about_page.dart';
import 'backup_page.dart';
import 'list_editors.dart';
import 'logs_page.dart';
import 'theme_page.dart';

/// "Tools" in FlClash's navigation, in sections: 连接 (proxy, DNS, advanced),
/// 规则与转发 (domain / DNS / port lists), 应用 (theme, language, start-up,
/// browser, backup, logs), 桌面 (desktop only) and 关于 (updates, links).
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  void _open(BuildContext context, String title, Widget Function() body) =>
      pushPage(context, (_) => AppPage(canPop: true, title: title, body: body()));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(settingsPendingProvider);
    final s = ref.watch(settingsProvider);
    final mobile = isMobileLayout(context);
    return AppPage(
      title: context.tr('tools'),
      body: PageList(children: [
        if (pending)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: DashboardBlock(
              color: DashboardColors.of(context).warnContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(spacing: 10, children: [
                GlyphIcon(AppGlyphs.info, size: 20, color: DashboardColors.of(context).onWarnContainer),
                Expanded(
                  child: Text(context.tr('apply_next_connect'),
                      style: AppTextStyle.footnote.of(context).copyWith(color: DashboardColors.of(context).onWarnContainer)),
                ),
              ]),
            ),
          ),
        // Connection: how the core is reached and talks to the network.
        SettingsGroup(title: context.tr('section_connection'), children: [
          SettingsTile(
            glyph: AppGlyphs.connections,
            title: context.tr('proxy'),
            subtitle: context.tr('proxy_desc'),
            trailing: Text('${s.socksPort} · ${s.httpPort}', style: DashboardText.label(context)),
            chevron: true,
            onTap: () => _open(context, context.tr('proxy'), () => const _ProxySettings()),
          ),
          SettingsTile(
            glyph: AppGlyphs.dns,
            title: 'DNS',
            subtitle: context.tr('dns_desc'),
            trailing: s.disableRemoteDns ? Text(context.tr('off'), style: DashboardText.label(context)) : null,
            chevron: true,
            onTap: () => _open(context, 'DNS', () => const _DnsSettings()),
          ),
          SettingsTile(
            glyph: AppGlyphs.sliders,
            title: context.tr('advanced'),
            subtitle: context.tr('advanced_desc'),
            chevron: true,
            onTap: () => _open(context, context.tr('advanced'), () => const _AdvancedSettings()),
          ),
          SwitchTile(
            glyph: AppGlyphs.sync,
            title: context.tr('auto_reconnect'),
            subtitle: context.tr('auto_reconnect_desc'),
            value: s.autoReconnect,
            onChanged: (v) => ref.read(settingsProvider.notifier).update((x) => x.autoReconnect = v),
          ),
          if (s.autoReconnect)
            IntTile(
              title: context.tr('reconnect_delay'),
              value: s.reconnectDelay,
              min: 1,
              max: 3600,
              onChanged: (v) => ref.read(settingsProvider.notifier).update((x) => x.reconnectDelay = v),
            ),
        ]),
        // Rules: per-domain / per-port lists the user maintains.
        SettingsGroup(title: context.tr('section_rules'), children: [
          SettingsTile(
            glyph: AppGlyphs.rules,
            title: context.tr('custom_proxy_domain'),
            subtitle: context.tr('custom_proxy_domain_desc'),
            trailing: Text('${s.customProxyDomains.length}', style: DashboardText.label(context)),
            chevron: true,
            onTap: () => _open(context, context.tr('custom_proxy_domain'), () => const ProxyDomainEditor()),
          ),
          SettingsTile(
            glyph: AppGlyphs.edit,
            title: context.tr('custom_dns'),
            subtitle: context.tr('custom_dns_desc'),
            trailing: Text('${s.customDns.length}', style: DashboardText.label(context)),
            chevron: true,
            onTap: () => _open(context, context.tr('custom_dns'), () => const CustomDnsEditor()),
          ),
          SettingsTile(
            glyph: AppGlyphs.swap,
            title: context.tr('port_forwarding'),
            subtitle: context.tr('port_forwarding_desc'),
            trailing: Text('${s.portForwards.length}', style: DashboardText.label(context)),
            chevron: true,
            onTap: () => _open(context, context.tr('port_forwarding'), () => const PortForwardEditor()),
          ),
        ]),
        _AppSettings(mobile: mobile),
        if (DesktopWindow.isDesktop) const _DesktopSettings(),
        const _AboutEntry(),
      ]),
    );
  }
}

class _ProxySettings extends ConsumerWidget {
  const _ProxySettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return PageList(children: [
      SettingsGroup(children: [
        IntTile(title: context.tr('socks_port'), value: s.socksPort, max: 65535, onChanged: (v) => n.update((x) => x.socksPort = v)),
        IntTile(title: context.tr('http_port'), value: s.httpPort, max: 65535, onChanged: (v) => n.update((x) => x.httpPort = v)),
        SwitchTile(title: context.tr('allow_lan'), subtitle: '0.0.0.0', value: s.allowLan, onChanged: (v) => n.update((x) => x.allowLan = v)),
      ]),
      SettingsGroup(title: context.tr('front_proxy'), footer: context.tr('front_proxy_hint'), children: [
        SettingsTile(
            title: context.tr('front_proxy_url'),
            subtitle: s.dialDirectProxy.isEmpty ? 'socks5://127.0.0.1:7890' : s.dialDirectProxy,
            chevron: true,
            onTap: () => _editFrontProxy(context, ref)),
        if (Platform.isAndroid)
          SettingsTile(
            title: context.tr('bypass_apps'),
            subtitle: '${s.bypassApps.length}',
            chevron: true,
            onTap: () => pushPage(context, (_) => AppPage(canPop: true, title: context.tr('bypass_apps'), body: const BypassAppsEditor())),
          ),
      ]),
      SettingsGroup(title: context.tr('socks_auth'), children: [
        TextTile(title: context.tr('username'), value: s.socksUser, onChanged: (v) => n.update((x) => x.socksUser = v)),
        TextTile(title: context.tr('password'), value: s.socksPassword, obscure: true, onChanged: (v) => n.update((x) => x.socksPassword = v)),
      ]),
      SettingsGroup(children: [
        TextTile(
            title: context.tr('shadowsocks_url'),
            value: s.shadowsocksUrl,
            hint: 'ss://AEAD_CHACHA20_POLY1305:password@:8388',
            onChanged: (v) => n.update((x) => x.shadowsocksUrl = v)),
        SwitchTile(title: context.tr('proxy_all'), value: s.proxyAll, onChanged: (v) => n.update((x) => x.proxyAll = v)),
        SwitchTile(title: context.tr('tcp_tunnel_mode'), value: s.tcpTunnelMode, onChanged: (v) => n.update((x) => x.tcpTunnelMode = v)),
      ]),
    ]);
  }
}

class _DnsSettings extends ConsumerWidget {
  const _DnsSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return PageList(children: [
      SettingsGroup(children: [
        SwitchTile(title: context.tr('remote_dns'), value: !s.disableRemoteDns, onChanged: (v) => n.update((x) => x.disableRemoteDns = !v)),
        TextTile(title: context.tr('remote_dns_server'), value: s.remoteDnsServer, hint: 'auto', onChanged: (v) => n.update((x) => x.remoteDnsServer = v.isEmpty ? 'auto' : v)),
        TextTile(title: context.tr('secondary_dns_server'), value: s.secondaryDnsServer, hint: 'auto', onChanged: (v) => n.update((x) => x.secondaryDnsServer = v.isEmpty ? 'auto' : v)),
        TextTile(title: context.tr('local_dns_server'), value: s.localDnsServer, hint: Platform.isAndroid ? 'system' : '223.5.5.5', onChanged: (v) => n.update((x) => x.localDnsServer = v)),
      ]),
      SettingsGroup(children: [
        TextTile(title: context.tr('dns_server_bind'), value: s.dnsServerBind, hint: '127.0.0.1:53', onChanged: (v) => n.update((x) => x.dnsServerBind = v)),
        IntTile(title: context.tr('dns_ttl'), value: s.dnsTtl, max: 86400 * 7, onChanged: (v) => n.update((x) => x.dnsTtl = v)),
        if (!Platform.isAndroid) ...[
          SwitchTile(title: context.tr('dns_hijack'), value: s.dnsHijack, onChanged: (v) => n.update((x) => x.dnsHijack = v)),
          SwitchTile(title: context.tr('fake_ip'), value: s.fakeIp, onChanged: (v) => n.update((x) => x.fakeIp = v)),
        ],
      ]),
    ]);
  }
}

class _AdvancedSettings extends ConsumerWidget {
  const _AdvancedSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return PageList(children: [
      SettingsGroup(title: context.tr('route_keepalive'), children: [
        SwitchTile(title: context.tr('add_route'), subtitle: context.tr('add_route_desc'), value: s.addRoute, onChanged: (v) => n.update((x) => x.addRoute = v)),
        SwitchTile(title: context.tr('keep_alive'), subtitle: context.tr('keep_alive_desc'), value: !s.disableKeepAlive, onChanged: (v) => n.update((x) => x.disableKeepAlive = !v)),
        TextTile(title: context.tr('keep_alive_url'), value: s.keepAliveUrl, hint: 'https://<内网地址>/favicon.ico', onChanged: (v) => n.update((x) => x.keepAliveUrl = v)),
      ]),
      if (!Platform.isAndroid)
        SettingsGroup(title: context.tr('outbound_interface'), footer: context.tr('outbound_interface_hint'), children: [
          TextTile(title: context.tr('bind_interface'), value: s.bindInterface, hint: 'eth0 / Wi-Fi', onChanged: (v) => n.update((x) => x.bindInterface = v)),
          SwitchTile(title: context.tr('auto_detect_interface'), value: s.autoDetectInterface, onChanged: (v) => n.update((x) => x.autoDetectInterface = v)),
        ]),
      SettingsGroup(title: 'aTrust', children: [
        IntTile(title: context.tr('best_nodes_interval'), value: s.updateBestNodesInterval, max: 86400, onChanged: (v) => n.update((x) => x.updateBestNodesInterval = v)),
        IntTile(title: context.tr('session_refresh_interval'), value: s.sessionRefreshInterval, max: 86400, onChanged: (v) => n.update((x) => x.sessionRefreshInterval = v)),
      ]),
      SettingsGroup(title: context.tr('extra_args'), footer: context.tr('extra_args_hint'), children: [
        SettingsTile(
          title: context.tr('extra_args'),
          subtitle: s.extraArgs.trim().isEmpty ? '-disable-multi-line -dns-ttl 600' : s.extraArgs.trim().replaceAll('\n', ' '),
          chevron: true,
          onTap: () => _editExtraArgs(context, ref),
        ),
      ]),
      SettingsGroup(title: context.tr('debug'), footer: context.tr('debug_warning'), children: [
        SwitchTile(title: context.tr('debug_dump'), value: s.debugDump, onChanged: (v) => n.update((x) => x.debugDump = v)),
        SwitchTile(
            title: context.tr('debug_pcap'),
            subtitle: context.tr('debug_pcap_desc'),
            value: s.debugPcap,
            onChanged: (v) => n.update((x) => x.debugPcap = v)),
        SwitchTile(
            title: context.tr('debug_tls_keylog'),
            subtitle: context.tr('debug_tls_keylog_desc'),
            value: s.debugTlsKeyLog,
            onChanged: (v) => n.update((x) => x.debugTlsKeyLog = v)),
        SettingsTile(
          title: context.tr('debug_files'),
          subtitle: context.tr('debug_files_desc'),
          chevron: true,
          onTap: () => pushPage(context, (_) => AppPage(canPop: true, title: context.tr('debug_files'), body: const DebugFilesPage())),
        ),
      ]),
    ]);
  }
}

/// Desktop only: launch at login, start minimised, close to tray, Dock icon.
class _DesktopSettings extends ConsumerStatefulWidget {
  const _DesktopSettings();

  @override
  ConsumerState<_DesktopSettings> createState() => _DesktopSettingsState();
}

class _DesktopSettingsState extends ConsumerState<_DesktopSettings> {
  bool? _autostart;

  @override
  void initState() {
    super.initState();
    Autostart.isEnabled().then((v) {
      if (mounted) setState(() => _autostart = v);
    });
  }

  Future<void> _setAutostart(bool on) async {
    final ok = await Autostart.set(on, hidden: ref.read(settingsProvider).silentStart);
    if (!mounted) return;
    if (!ok) showToast(context, context.tr('autostart_failed'), level: BannerLevel.error);
    final now = await Autostart.isEnabled();
    if (mounted) setState(() => _autostart = now);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return SettingsGroup(title: context.tr('desktop'), children: [
      SwitchTile(
        glyph: AppGlyphs.toggle,
        title: context.tr('launch_at_login'),
        subtitle: context.tr('launch_at_login_desc'),
        value: _autostart ?? false,
        onChanged: _autostart == null ? null : _setAutostart,
      ),
      SwitchTile(
        glyph: AppGlyphs.eyeOff,
        title: context.tr('silent_start'),
        subtitle: context.tr('silent_start_desc'),
        value: s.silentStart,
        onChanged: (v) async {
          n.update((x) => x.silentStart = v);
          // Rewrite the login entry so it passes (or drops) --hidden.
          if (_autostart == true) await Autostart.set(true, hidden: v);
        },
      ),
      SwitchTile(
        glyph: AppGlyphs.layers,
        title: context.tr('close_to_tray'),
        subtitle: context.tr('close_to_tray_desc'),
        value: s.closeToTray,
        onChanged: (v) => n.update((x) => x.closeToTray = v),
      ),
      SwitchTile(
        glyph: AppGlyphs.eyeOff,
        title: context.tr('minimize_to_tray'),
        subtitle: context.tr('minimize_to_tray_desc'),
        value: s.minimizeToTray,
        onChanged: (v) => n.update((x) => x.minimizeToTray = v),
      ),
      SettingsTile(
        glyph: AppGlyphs.connections,
        title: context.tr('system_proxy'),
        subtitle: context.tr('system_proxy_desc'),
        chevron: true,
        onTap: () => pushPage(
            context, (_) => AppPage(canPop: true, title: context.tr('system_proxy'), body: const _SystemProxySettings())),
      ),
      if (Platform.isMacOS)
        SwitchTile(
          glyph: AppGlyphs.iconTile,
          title: context.tr('hide_dock_icon'),
          subtitle: context.tr('hide_dock_icon_desc'),
          value: s.hideDockIcon,
          onChanged: (v) {
            n.update((x) => x.hideDockIcon = v);
            DesktopWindow.setDockIconVisible(!v);
          },
        ),
    ]);
  }
}

/// Desktop system proxy: extra exclusions, the "replace another app's
/// proxy?" prompt, and a manual clean-up.
class _SystemProxySettings extends ConsumerWidget {
  const _SystemProxySettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    return PageList(children: [
      SettingsGroup(footer: context.tr('proxy_bypass_footer'), children: [
        TextTile(
          title: context.tr('proxy_bypass'),
          value: s.systemProxyBypass,
          hint: '*.example.com;192.0.2.*',
          onChanged: (v) => n.update((x) => x.systemProxyBypass = v),
        ),
      ]),
      SettingsGroup(children: [
        SwitchTile(
          title: context.tr('warn_proxy_override'),
          subtitle: context.tr('warn_proxy_override_desc'),
          value: s.warnProxyOverride,
          onChanged: (v) => n.update((x) => x.warnProxyOverride = v),
        ),
        SettingsTile(
          title: context.tr('clear_system_proxy'),
          subtitle: context.tr('clear_system_proxy_desc'),
          destructive: true,
          onTap: () async {
            final ok = await confirm(context,
                title: context.tr('clear_system_proxy'), message: context.tr('clear_system_proxy_confirm'), destructive: true);
            if (!ok) return;
            await SystemProxy.clear(ref.read(dataDirProvider));
            if (context.mounted) showToast(context, context.tr('clear_system_proxy_done'), level: BannerLevel.success);
          },
        ),
      ]),
    ]);
  }
}

/// PCAP / TLS key-log files written by the core (one pair per connection).
class DebugFilesPage extends ConsumerStatefulWidget {
  const DebugFilesPage({super.key});

  @override
  ConsumerState<DebugFilesPage> createState() => _DebugFilesPageState();
}

class _DebugFilesPageState extends ConsumerState<DebugFilesPage> {
  List<File> _files = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Directory get _dir => Directory(debugDir(ref.read(dataDirProvider)));

  void _load() {
    try {
      final l = _dir.existsSync() ? _dir.listSync().whereType<File>().toList() : <File>[];
      l.sort((a, b) => b.path.compareTo(a.path));
      setState(() => _files = l);
    } catch (_) {}
  }

  Future<void> _export(File f) async {
    try {
      final r = await FilePicker.saveFile(fileName: p.basename(f.path), bytes: await f.readAsBytes());
      if (r != null && mounted) showToast(context, context.tr('saved'), level: BannerLevel.success);
    } catch (e) {
      if (mounted) showToast(context, '$e', level: BannerLevel.error);
    }
  }

  String _size(int b) => b < 1024 ? '$b B' : b < 1 << 20 ? '${(b / 1024).toStringAsFixed(1)} KB' : '${(b / (1 << 20)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    return PageList(children: [
      SettingsGroup(children: [
        if (_files.isEmpty) SettingsTile(title: context.tr('debug_files_empty')),
        for (final f in _files)
          SettingsTile(
            glyph: AppGlyphs.logs,
            title: p.basename(f.path),
            subtitle: _size(f.existsSync() ? f.lengthSync() : 0),
            trailing: GlyphIcon(AppGlyphs.openExternal, size: 18, color: context.colorScheme.onSurfaceVariant),
            onTap: () => _export(f),
          ),
      ]),
      SettingsGroup(children: [
        if (DesktopWindow.isDesktop)
          SettingsTile(
            glyph: AppGlyphs.openExternal,
            title: context.tr('open_folder'),
            onTap: () {
              _dir.createSync(recursive: true);
              launchUrl(Uri.directory(_dir.path));
            },
          ),
        SettingsTile(
          glyph: AppGlyphs.clearAll,
          title: context.tr('delete_all'),
          destructive: true,
          onTap: _files.isEmpty
              ? null
              : () async {
                  final ok = await confirm(context, title: context.tr('delete_all'), destructive: true);
                  if (!ok) return;
                  for (final f in _files) {
                    try {
                      f.deleteSync();
                    } catch (_) {}
                  }
                  _load();
                },
        ),
      ]),
    ]);
  }
}

/// Multi-line editor for [AppSettings.extraArgs]; warns about options the
/// parser does not accept (they would stop the next connection).
Future<void> _editExtraArgs(BuildContext context, WidgetRef ref) async {
  final c = TextEditingController(text: ref.read(settingsProvider).extraArgs);
  final v = await showFloatingDialog<String>(
    context: context,
    child: Builder(
      builder: (ctx) => AlertDialog(
        title: ctx.tr('extra_args'),
        hasFields: true,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.tr('cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text(ctx.tr('ok'))),
        ],
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 10, children: [
          Text(ctx.tr('extra_args_hint'), style: DashboardText.label(ctx)),
          TextField(
            controller: c,
            autofocus: true,
            autocorrect: false,
            minLines: 3,
            maxLines: 8,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(hintText: '-disable-multi-line\n-dns-ttl 600'),
          ),
        ]),
      ),
    ),
  );
  if (v == null || !context.mounted) return;
  final text = v.trim();
  ref.read(settingsProvider.notifier).update((x) => x.extraArgs = text);
  final errs = parseExtraArgs(text).errors;
  if (errs.isNotEmpty) {
    await notice(context, title: context.tr('extra_args'), message: context.tr('extra_args_invalid', {'e': errs.join('\n')}));
  }
}

/// App: appearance, language, start-up behaviour, data and logs.
class _AppSettings extends ConsumerWidget {
  const _AppSettings({required this.mobile});

  final bool mobile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final mode = switch (s.themeMode) {
      AppThemeMode.system => context.tr('theme_system'),
      AppThemeMode.light => context.tr('theme_light'),
      AppThemeMode.dark => context.tr('theme_dark'),
    };
    return SettingsGroup(title: context.tr('section_app'), children: [
      SettingsTile(
        glyph: AppGlyphs.paintbrush,
        title: context.tr('theme'),
        subtitle: context.tr(appIconSupported ? 'theme_desc' : 'theme_desc_no_icon'),
        trailing: Text(mode, style: DashboardText.label(context)),
        chevron: true,
        onTap: () => pushPage(context, (_) => AppPage(canPop: true, title: context.tr('theme'), body: const ThemePage())),
      ),
      SettingsTile(
        glyph: AppGlyphs.language,
        title: context.tr('language'),
        subtitle: context.tr('language_desc'),
        trailing: Text(switch (s.locale) { 'zh' => '中文', 'en' => 'English', _ => context.tr('follow_system') },
            style: DashboardText.label(context)),
        chevron: true,
        onTap: () async {
          final v = await pickOne<String>(context,
              title: context.tr('language'),
              current: s.locale,
              options: [('', context.tr('follow_system')), ('zh', '中文'), ('en', 'English')]);
          if (v != null) n.update((x) => x.locale = v);
        },
      ),
      SwitchTile(
        glyph: AppGlyphs.bolt,
        title: context.tr('auto_connect'),
        subtitle: context.tr('auto_connect_desc'),
        value: s.autoConnect,
        onChanged: (v) => n.update((x) => x.autoConnect = v),
      ),
      SwitchTile(
        glyph: AppGlyphs.info,
        title: context.tr('notifications'),
        subtitle: context.tr('notifications_desc'),
        value: s.notifications,
        onChanged: (v) => n.update((x) => x.notifications = v),
      ),
      if (Platform.isAndroid)
        FutureBuilder<String?>(
          future: appLabel(s.browserPackage),
          builder: (context, snap) => SettingsTile(
            glyph: AppGlyphs.openExternal,
            title: context.tr('browser'),
            subtitle: s.browserPackage.isEmpty ? context.tr('browser_default') : (snap.data ?? s.browserPackage),
            chevron: true,
            onTap: () => pushPage(
              context,
              (_) => AppPage(
                canPop: true,
                title: context.tr('browser'),
                body: Consumer(
                  builder: (pageContext, ref, _) => AppListView(
                    browsers: true,
                    noneLabel: context.tr('browser_default'),
                    selectedOne: ref.watch(settingsProvider.select((x) => x.browserPackage)),
                    onPick: (pkg) {
                      n.update((x) => x.browserPackage = pkg);
                      Navigator.of(pageContext).pop();
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      SettingsTile(
        glyph: AppGlyphs.cloudSync,
        title: context.tr('backup_restore'),
        subtitle: context.tr('backup_restore_sub'),
        chevron: true,
        onTap: () => pushPage(context, (_) => AppPage(canPop: true, title: context.tr('backup_restore'), body: const BackupPage())),
      ),
      if (mobile)
        SettingsTile(
          glyph: AppGlyphs.logs,
          title: context.tr('logs'),
          subtitle: context.tr('logs_desc'),
          chevron: true,
          onTap: () => pushPage(context, (_) => const LogsPage(pushed: true)),
        ),
    ]);
  }
}

/// One 关于 entry opening the About page (FlClash style secondary page).
class _AboutEntry extends StatefulWidget {
  const _AboutEntry();

  @override
  State<_AboutEntry> createState() => _AboutEntryState();
}

class _AboutEntryState extends State<_AboutEntry> {
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    currentAppVersion().then((v) {
      if (mounted) setState(() => _appVersion = v);
    });
  }

  @override
  Widget build(BuildContext context) => SettingsGroup(children: [
        SettingsTile(
          glyph: AppGlyphs.info,
          title: context.tr('about'),
          subtitle: context.tr('about_entry_desc'),
          trailing: Text(_appVersion.isEmpty ? '' : 'v$_appVersion', style: DashboardText.label(context)),
          chevron: true,
          onTap: () => pushPage(context, (_) => const AboutPage()),
        ),
      ]);
}

/// Add / change the external proxy: it is saved only when it answers as the
/// right kind of proxy; on Android the app serving a local proxy is then
/// looked up and, after the user agrees, kept out of the VPN.
Future<void> _editFrontProxy(BuildContext context, WidgetRef ref) async {
  final n = ref.read(settingsProvider.notifier);
  final current = ref.read(settingsProvider).dialDirectProxy;
  final v = await editTextDialog(context,
      title: context.tr('front_proxy_url'), initial: current, hint: 'socks5://127.0.0.1:7890');
  if (v == null || !context.mounted) return;
  final text = v.trim();
  if (text.isEmpty) {
    n.update((x) => x.dialDirectProxy = '');
    return;
  }
  final url = ProxyUrl.parse(text);
  if (url == null) {
    await notice(context, title: context.tr('front_proxy_url'), message: context.tr('proxy_bad_url'));
    return;
  }
  showToast(context, context.tr('proxy_checking'));
  final r = await probeProxy(url);
  if (!context.mounted) return;
  if (!r.ok) {
    await notice(context,
        title: context.tr('front_proxy_url'),
        message: r.wrongKind
            ? context.tr('proxy_not_socks', {'proxy': text, 'kind': url.kind == 'socks' ? 'SOCKS5' : 'HTTP'})
            : context.tr('proxy_unreachable', {'proxy': text, 'reason': r.error ?? ''}));
    return;
  }
  n.update((x) => x.dialDirectProxy = text);
  if (!Platform.isAndroid) return;

  final port = '${url.port}';
  String? reason;
  if (!url.isLocal) {
    reason = context.tr('proxy_owner_reason_remote');
  } else {
    final o = await probeProxyOwner(url.port);
    if (!context.mounted) return;
    final status = o['status'] as String? ?? 'error';
    final msg = o['message'] as String?;
    if (status == 'found') {
      final pkg = o['package'] as String;
      final app = (o['label'] as String?) ?? pkg;
      if (ref.read(settingsProvider).bypassApps.contains(pkg)) {
        await notice(context, title: context.tr('bypass_apps'), message: context.tr('proxy_owner_already', {'app': app, 'port': port}));
        return;
      }
      final yes = await confirm(context,
          title: context.tr('proxy_owner_title', {'app': app}),
          message: context.tr('proxy_owner_msg', {'app': app, 'pkg': pkg, 'port': port}));
      if (yes) n.update((x) => x.bypassApps.add(pkg));
      return;
    }
    reason = switch (status) {
      'other_vpn' => context.tr('proxy_owner_reason_other_vpn'),
      'no_permission' => context.tr('proxy_owner_reason_no_permission'),
      'unsupported' => context.tr('proxy_owner_reason_unsupported'),
      'vpn_running' => context.tr('proxy_owner_reason_vpn_running'),
      'not_found' => context.tr('proxy_owner_reason_not_found', {'port': port}) + (msg == null ? '' : '\n${context.tr('detail')}: $msg'),
      _ => context.tr('proxy_owner_reason_error', {'reason': msg ?? status}),
    };
  }
  await notice(context,
      title: context.tr('proxy_owner_unknown_title'),
      message: url.isLocal ? '$reason\n${context.tr('proxy_owner_manual')}' : reason);
}
