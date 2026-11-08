import 'dart:io';


enum AppThemeMode { system, light, dark }

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
    this.addRoute = false,
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
    this.appIcon = 'a1',
    this.shareWarningSeen = false,
    this.useDynamicColor = false,
    this.locale = '',
    this.autoConnect = false,
    this.closeToTray = true,
    this.silentStart = false,
    this.hideDockIcon = false,
    this.autoCheckUpdate = true,
    this.selectedProfileId,
  })  : trafficMode = trafficMode ?? defaultTrafficMode,
        portForwards = portForwards ?? [],
        customDns = customDns ?? [],
        customProxyDomains = customProxyDomains ?? [],
        bypassApps = bypassApps ?? List.of(defaultBypassApps),
        favoriteResources = favoriteResources ?? [];

  /// Android: VPN (like the old app). Desktop: system proxy, like FlClash —
  /// TUN needs administrator rights.
  static TrafficMode get defaultTrafficMode =>
      Platform.isAndroid ? TrafficMode.tun : TrafficMode.systemProxy;

  TrafficMode trafficMode;
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
  int seedColor;
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
  /// Check GitHub Releases for a new version on launch (at most once a day).
  bool autoCheckUpdate;
  String? selectedProfileId;

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
        'appIcon': appIcon,
        'shareWarningSeen': shareWarningSeen,
        'useDynamicColor': useDynamicColor,
        'locale': locale,
        'autoConnect': autoConnect,
        'closeToTray': closeToTray,
        'silentStart': silentStart,
        'hideDockIcon': hideDockIcon,
        'autoCheckUpdate': autoCheckUpdate,
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
      addRoute: v('addRoute', false),
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
      appIcon: v('appIcon', 'a1'),
      shareWarningSeen: v('shareWarningSeen', false),
      useDynamicColor: v('useDynamicColor', false),
      locale: v('locale', ''),
      autoConnect: v('autoConnect', false),
      closeToTray: v('closeToTray', true),
      silentStart: v('silentStart', false),
      hideDockIcon: v('hideDockIcon', false),
      autoCheckUpdate: v('autoCheckUpdate', true),
      selectedProfileId: j['selectedProfileId'] as String?,
    );
  }
}
