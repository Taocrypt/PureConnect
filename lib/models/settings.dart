import 'dart:io';


enum AppThemeMode { system, light, dark }

/// FlClash's default primary colours (iOS system colours, in the order of the
/// macOS accent colours). The first is the default primary.
const defaultPrimaryColors = [
  0xFF007AFF,
  0xFFCB30E0,
  0xFFFF2D55,
  0xFFFF383C,
  0xFFFF8D28,
  0xFFFFCC00,
  0xFF34C759,
  0xFF8E8E93,
];
const defaultPrimaryColor = 0xFF007AFF;

/// Text scale range of the theme page's slider (FlClash's).
const minTextScale = 0.8;
const maxTextScale = 1.4;

/// Version of the first-launch disclaimer. Raising it shows the disclaimer
/// again, once, to everyone who accepted an older one.
const disclaimerVersion = 1;

/// Colour style of the generated scheme (prism_ui ColorStyle names).
const colorStyles = ['vivid', 'tinted', 'soft', 'monochrome'];

/// Liquid glass on the floating navigation dock.
const liquidGlassModes = ['none', 'standard', 'ultra'];

/// Whether the first-launch disclaimer still has to be shown, i.e. the user
/// has not accepted the current [disclaimerVersion] (users updating from a
/// version without it have 0).
bool needsDisclaimer(int accepted) => accepted < disclaimerVersion;

class PortForward {
  PortForward({this.network = 'tcp', this.bind = '', this.remote = ''});
  String network; // tcp | udp
  String bind; // 127.0.0.1:8080
  String remote; // 10.10.98.98:80

  Map<String, dynamic> toJson() =>
      {'network': network, 'bind': bind, 'remote': remote};
  factory PortForward.fromJson(Map<String, dynamic> j) => PortForward(
        network: j['network'] as String? ?? 'tcp',
        bind: j['bind'] as String? ?? '',
        remote: j['remote'] as String? ?? '',
      );
}

class CustomDns {
  CustomDns({this.host = '', this.ip = ''});
  String host;
  String ip;
  Map<String, dynamic> toJson() => {'host': host, 'ip': ip};
  factory CustomDns.fromJson(Map<String, dynamic> j) =>
      CustomDns(host: j['host'] as String? ?? '', ip: j['ip'] as String? ?? '');
}

/// How traffic reaches the core.
enum TrafficMode {
  /// SOCKS5/HTTP proxy only (no system changes).
  proxy,

  /// Proxy + set the OS system proxy (desktop).
  systemProxy,

  /// Android VpnService / desktop TUN device (needs admin on desktop).
  tun,
}

/// Network + app behaviour shared by every profile.
/// Common Clash-family clients; missing packages are skipped at runtime.
const defaultBypassApps = [
  'com.follow.clash', // FlClash
  'com.github.metacubex.clash.meta', // Clash Meta for Android
  'com.github.kr328.clash', // Clash for Android
  'com.github.kr328.clash.foss',
  'io.nekohasekai.sfa', // sing-box
  'com.v2ray.ang', // v2rayNG
];

class AppSettings {
  AppSettings({
    TrafficMode? trafficMode,
    this.allowLan = false,
    this.socksPort = 1080,
    this.httpPort = 1081,
    this.socksUser = '',
    this.socksPassword = '',
    this.shadowsocksUrl = '',
    this.dialDirectProxy = '',
    this.proxyAll = false,
    List<String>? bypassApps,
    List<String>? favoriteResources,
    this.browserPackage = '',
    this.tcpTunnelMode = false,
    this.disableRemoteDns = false,
    this.remoteDnsServer = 'auto',
    this.secondaryDnsServer = 'auto',
    this.localDnsServer = '',
    this.dnsServerBind = '',
    this.dnsTtl = 3600,
    this.dnsHijack = false,
    this.fakeIp = false,
    this.addRoute = true,
    this.disableKeepAlive = false,
    this.keepAliveUrl = '',
    this.bindInterface = '',
    this.autoDetectInterface = false,
    this.debugDump = false,
    this.updateBestNodesInterval = 300,
    this.sessionRefreshInterval = 1800,
    List<PortForward>? portForwards,
    List<CustomDns>? customDns,
    List<String>? customProxyDomains,
    this.themeMode = AppThemeMode.system,
    this.seedColor = 0xFF007AFF,
    List<int>? primaryColors,
    this.colorStyle = 'vivid',
    this.pureBlack = false,
    this.sidebarBlur = false,
    this.liquidGlass = 'none',
    this.floatingNavBar = true,
    this.tabAnimation = 'slide',
    this.customTextScale = false,
    this.textScale = 1.0,
    this.fontFamily = '',
    this.disclaimerAccepted = 0,
    this.appIcon = 'a1',
    this.shareWarningSeen = false,
    this.useDynamicColor = false,
    this.locale = '',
    this.autoConnect = false,
    this.closeToTray = true,
    this.silentStart = false,
    this.hideDockIcon = false,
    this.autoCheckUpdate = true,
    this.updateMirrorMode = 'auto',
    List<String>? updateMirrors,
    this.autoReconnect = false,
    this.reconnectDelay = 5,
    this.notifications = true,
    this.minimizeToTray = false,
    this.lightweightMode = false,
    this.lightweightMinutes = 3,
    this.systemProxyBypass = '',
    this.warnProxyOverride = true,
    this.debugPcap = false,
    this.debugTlsKeyLog = false,
    this.extraArgs = '',
    this.setupGuideShown = false,
    this.selectedProfileId,
  })  : trafficMode = trafficMode ?? defaultTrafficMode,
        portForwards = portForwards ?? [],
        customDns = customDns ?? [],
        customProxyDomains = customProxyDomains ?? [],
        bypassApps = bypassApps ?? List.of(defaultBypassApps),
        favoriteResources = favoriteResources ?? [],
        updateMirrors = updateMirrors ?? [],
        primaryColors = primaryColors ?? List.of(defaultPrimaryColors);

  /// Android: VPN (like the old app). Desktop: system proxy, like FlClash —
  /// TUN needs administrator rights.
  static TrafficMode get defaultTrafficMode =>
      Platform.isAndroid ? TrafficMode.tun : TrafficMode.systemProxy;

  TrafficMode trafficMode;

  /// Whether connecting in [mode] points the OS system proxy at the core's
  /// HTTP/SOCKS ports (desktop only). System-proxy mode always does. Desktop
  /// TUN does too when an external proxy is set: the TUN device only carries
  /// campus routes, so other traffic never reached the core and the external
  /// proxy was never used; through the system proxy, campus traffic still
  /// goes to the VPN and everything else to the external proxy.
  bool setsSystemProxy(TrafficMode mode, {required bool android}) {
    if (android) return false;
    if (httpPort <= 0 && socksPort <= 0) return false;
    return mode == TrafficMode.systemProxy ||
        (mode == TrafficMode.tun && dialDirectProxy.trim().isNotEmpty);
  }

  bool allowLan;
  int socksPort; // 0 = off
  int httpPort; // 0 = off
  String socksUser;
  String socksPassword;
  String shadowsocksUrl;
  String dialDirectProxy;
  bool proxyAll;
  /// Android: apps kept outside the VPN (the front proxy app itself).
  List<String> bypassApps;
  /// Web resources pinned to 我的收藏 (keys from WebResource.favKey).
  List<String> favoriteResources;
  /// Android: package that opens web links; empty = system default.
  String browserPackage;
  bool tcpTunnelMode;

  bool disableRemoteDns;
  String remoteDnsServer;
  String secondaryDnsServer;
  String localDnsServer;
  String dnsServerBind;
  int dnsTtl;
  bool dnsHijack;
  bool fakeIp;
  bool addRoute;

  bool disableKeepAlive;
  String keepAliveUrl;
  String bindInterface;
  bool autoDetectInterface;
  bool debugDump;
  int updateBestNodesInterval;
  int sessionRefreshInterval;

  List<PortForward> portForwards;
  List<CustomDns> customDns;
  List<String> customProxyDomains;

  AppThemeMode themeMode;
  /// Selected primary colour (ignored while [useDynamicColor] follows the
  /// system accent).
  int seedColor;
  /// The swatches of the theme page: presets plus the user's own colours.
  List<int> primaryColors;
  /// prism_ui ColorStyle name: vivid / tinted / soft / monochrome.
  String colorStyle;
  /// Dark theme with black surfaces (AMOLED).
  bool pureBlack;
  /// Desktop (Windows / macOS): the sidebar shows the window's backdrop
  /// material (Mica / blur / vibrancy) behind it.
  bool sidebarBlur;
  /// none / standard / ultra liquid glass on the floating dock.
  String liquidGlass;
  /// Phone layout: floating dock (true) or a docked bar.
  bool floatingNavBar;
  /// Phone layout: switching tabs slides (slide) or cross-fades (fade).
  String tabAnimation;
  /// Use [textScale] instead of the system text size.
  bool customTextScale;
  double textScale;
  /// Installed font family the app uses; empty = the platform default.
  String fontFamily;
  /// Highest disclaimer version the user agreed to (0 = never).
  int disclaimerAccepted;
  /// App icon id (see core/app_icon.dart); Android launcher / Windows window.
  String appIcon;
  /// User ticked "don't show again" on the share-includes-password warning.
  bool shareWarningSeen;
  bool useDynamicColor;
  String locale; // '' = system, 'zh', 'en'
  bool autoConnect;
  /// Desktop: the close button hides the window to the tray / menu bar.
  bool closeToTray;
  /// Desktop: when launched at login, stay in the tray (no window).
  bool silentStart;
  /// macOS: no Dock icon (menu-bar only).
  bool hideDockIcon;
  /// Offer a new version found by the launch check. The launch check itself
  /// runs every launch regardless, so forced updates are always caught.
  bool autoCheckUpdate;
  /// Update downloads: 'auto' (direct when reachable, else built-in mirrors)
  /// or 'direct' (never built-in mirrors).
  String updateMirrorMode;
  /// User's own GitHub mirror prefixes, tried first in this order.
  List<String> updateMirrors;
  /// Reconnect by itself after the tunnel drops (network / session errors,
  /// never wrong credentials), after [reconnectDelay] seconds.
  bool autoReconnect;
  int reconnectDelay;
  /// System notifications: unexpected disconnect, reconnecting, hidden to tray.
  bool notifications;
  /// Desktop: minimising the window hides it to the tray.
  bool minimizeToTray;
  /// Lightweight mode (轻量模式): after the window has been hidden in the
  /// tray (desktop) or the app has been in the background (Android) for
  /// [lightweightMinutes] while connected, the UI exits and only the core
  /// keeps running; opening the app again re-attaches. Off by default.
  bool lightweightMode;
  int lightweightMinutes;
  /// Desktop: extra system-proxy exclusions (`;`, `,` or newline separated),
  /// added to the built-in local / private ranges.
  String systemProxyBypass;
  /// Desktop: ask before replacing a system proxy another app has set.
  bool warnProxyOverride;
  /// Save reconstructed VPN traffic as PCAP (`debug_pcap_file`).
  bool debugPcap;
  /// Save TLS session secrets in NSS key-log format (`debug_tls_log_file`).
  bool debugTlsKeyLog;
  /// Extra zju-connect command-line style options (see core/extra_args.dart).
  String extraArgs;
  /// The first-launch setup guide has been offered once.
  bool setupGuideShown;
  String? selectedProfileId;

  /// [systemProxyBypass] as a list.
  List<String> get systemProxyBypassList => systemProxyBypass
      .split(RegExp(r'[;,\s]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  AppSettings copy() => AppSettings.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'trafficMode': trafficMode.name,
        'allowLan': allowLan,
        'socksPort': socksPort,
        'httpPort': httpPort,
        'socksUser': socksUser,
        'socksPassword': socksPassword,
        'shadowsocksUrl': shadowsocksUrl,
        'dialDirectProxy': dialDirectProxy,
        'proxyAll': proxyAll,
        'bypassApps': bypassApps,
        'favoriteResources': favoriteResources,
        'browserPackage': browserPackage,
        'tcpTunnelMode': tcpTunnelMode,
        'disableRemoteDns': disableRemoteDns,
        'remoteDnsServer': remoteDnsServer,
        'secondaryDnsServer': secondaryDnsServer,
        'localDnsServer': localDnsServer,
        'dnsServerBind': dnsServerBind,
        'dnsTtl': dnsTtl,
        'dnsHijack': dnsHijack,
        'fakeIp': fakeIp,
        'addRoute': addRoute,
        'disableKeepAlive': disableKeepAlive,
        'keepAliveUrl': keepAliveUrl,
        'bindInterface': bindInterface,
        'autoDetectInterface': autoDetectInterface,
        'debugDump': debugDump,
        'updateBestNodesInterval': updateBestNodesInterval,
        'sessionRefreshInterval': sessionRefreshInterval,
        'portForwards': portForwards.map((e) => e.toJson()).toList(),
        'customDns': customDns.map((e) => e.toJson()).toList(),
        'customProxyDomains': customProxyDomains,
        'themeMode': themeMode.name,
        'seedColor': seedColor,
        'primaryColors': primaryColors,
        'colorStyle': colorStyle,
        'pureBlack': pureBlack,
        'sidebarBlur': sidebarBlur,
        'liquidGlass': liquidGlass,
        'floatingNavBar': floatingNavBar,
        'tabAnimation': tabAnimation,
        'customTextScale': customTextScale,
        'textScale': textScale,
        'fontFamily': fontFamily,
        'disclaimerAccepted': disclaimerAccepted,
        'appIcon': appIcon,
        'shareWarningSeen': shareWarningSeen,
        'useDynamicColor': useDynamicColor,
        'locale': locale,
        'autoConnect': autoConnect,
        'closeToTray': closeToTray,
        'silentStart': silentStart,
        'hideDockIcon': hideDockIcon,
        'autoCheckUpdate': autoCheckUpdate,
        'updateMirrorMode': updateMirrorMode,
        'updateMirrors': updateMirrors,
        'autoReconnect': autoReconnect,
        'reconnectDelay': reconnectDelay,
        'notifications': notifications,
        'minimizeToTray': minimizeToTray,
        'lightweightMode': lightweightMode,
        'lightweightMinutes': lightweightMinutes,
        'systemProxyBypass': systemProxyBypass,
        'warnProxyOverride': warnProxyOverride,
        'debugPcap': debugPcap,
        'debugTlsKeyLog': debugTlsKeyLog,
        'extraArgs': extraArgs,
        'setupGuideShown': setupGuideShown,
        'selectedProfileId': selectedProfileId,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) {
    T v<T>(String k, T d) => j[k] is T ? j[k] as T : d;
    return AppSettings(
      trafficMode: TrafficMode.values.firstWhere(
          (e) => e.name == j['trafficMode'],
          orElse: () => defaultTrafficMode),
      allowLan: v('allowLan', false),
      socksPort: v('socksPort', 1080),
      httpPort: v('httpPort', 1081),
      socksUser: v('socksUser', ''),
      socksPassword: v('socksPassword', ''),
      shadowsocksUrl: v('shadowsocksUrl', ''),
      dialDirectProxy: v('dialDirectProxy', ''),
      proxyAll: v('proxyAll', false),
      bypassApps: (j['bypassApps'] as List?)?.map((e) => e.toString()).toList(),
      favoriteResources: (j['favoriteResources'] as List?)?.map((e) => e.toString()).toList(),
      browserPackage: v('browserPackage', ''),
      tcpTunnelMode: v('tcpTunnelMode', false),
      disableRemoteDns: v('disableRemoteDns', false),
      remoteDnsServer: v('remoteDnsServer', 'auto'),
      secondaryDnsServer: v('secondaryDnsServer', 'auto'),
      localDnsServer: v('localDnsServer', ''),
      dnsServerBind: v('dnsServerBind', ''),
      dnsTtl: v('dnsTtl', 3600),
      dnsHijack: v('dnsHijack', false),
      fakeIp: v('fakeIp', false),
      addRoute: v('addRoute', true),
      disableKeepAlive: v('disableKeepAlive', false),
      keepAliveUrl: v('keepAliveUrl', ''),
      bindInterface: v('bindInterface', ''),
      autoDetectInterface: v('autoDetectInterface', false),
      debugDump: v('debugDump', false),
      updateBestNodesInterval: v('updateBestNodesInterval', 300),
      sessionRefreshInterval: v('sessionRefreshInterval', 1800),
      portForwards: (j['portForwards'] as List? ?? [])
          .map((e) => PortForward.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      customDns: (j['customDns'] as List? ?? [])
          .map((e) => CustomDns.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      customProxyDomains:
          (j['customProxyDomains'] as List? ?? []).cast<String>().toList(),
      themeMode: AppThemeMode.values.firstWhere((e) => e.name == j['themeMode'],
          orElse: () => AppThemeMode.system),
      seedColor: v('seedColor', 0xFF007AFF),
      primaryColors: _primaryColors(j['primaryColors'], v('seedColor', 0xFF007AFF)),
      colorStyle: colorStyles.contains(j['colorStyle']) ? j['colorStyle'] as String : 'vivid',
      pureBlack: v('pureBlack', false),
      sidebarBlur: v('sidebarBlur', false),
      liquidGlass: liquidGlassModes.contains(j['liquidGlass']) ? j['liquidGlass'] as String : 'none',
      floatingNavBar: v('floatingNavBar', true),
      tabAnimation: j['tabAnimation'] == 'fade' ? 'fade' : 'slide',
      customTextScale: v('customTextScale', false),
      textScale: (j['textScale'] is num ? (j['textScale'] as num).toDouble() : 1.0)
          .clamp(minTextScale, maxTextScale)
          .toDouble(),
      fontFamily: v('fontFamily', ''),
      disclaimerAccepted: v('disclaimerAccepted', 0),
      appIcon: v('appIcon', 'a1'),
      shareWarningSeen: v('shareWarningSeen', false),
      useDynamicColor: v('useDynamicColor', false),
      locale: v('locale', ''),
      autoConnect: v('autoConnect', false),
      closeToTray: v('closeToTray', true),
      silentStart: v('silentStart', false),
      hideDockIcon: v('hideDockIcon', false),
      autoCheckUpdate: v('autoCheckUpdate', true),
      updateMirrorMode: v('updateMirrorMode', 'auto'),
      updateMirrors: (j['updateMirrors'] as List?)?.map((e) => e.toString()).toList(),
      autoReconnect: v('autoReconnect', false),
      reconnectDelay: v('reconnectDelay', 5),
      notifications: v('notifications', true),
      minimizeToTray: v('minimizeToTray', false),
      lightweightMode: v('lightweightMode', false),
      lightweightMinutes: v('lightweightMinutes', 3).clamp(1, 1440).toInt(),
      systemProxyBypass: v('systemProxyBypass', ''),
      warnProxyOverride: v('warnProxyOverride', true),
      debugPcap: v('debugPcap', false),
      debugTlsKeyLog: v('debugTlsKeyLog', false),
      extraArgs: v('extraArgs', ''),
      setupGuideShown: v('setupGuideShown', false),
      selectedProfileId: j['selectedProfileId'] as String?,
    );
  }
}

/// Saved swatches; settings from before 1.0.3 have none, so they get the
/// presets plus their chosen colour when it is not one of them.
List<int> _primaryColors(Object? raw, int seed) {
  if (raw is List) {
    final l = <int>[];
    for (final e in raw) {
      if (e is int && !l.contains(e)) l.add(e);
    }
    return l;
  }
  return [...defaultPrimaryColors, if (!defaultPrimaryColors.contains(seed)) seed];
}
