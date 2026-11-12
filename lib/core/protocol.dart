/// Dart side of the zjuconnect-core JSON-lines protocol
/// (see core/bridge/protocol.go — keep in sync).
library;

enum CoreState { idle, starting, connecting, connected, stopping, stopped, error }

CoreState coreStateFrom(String? s) => switch (s) {
      'connecting' => CoreState.connecting,
      'connected' => CoreState.connected,
      'stopping' => CoreState.stopping,
      'stopped' => CoreState.stopped,
      'error' => CoreState.error,
      _ => CoreState.idle,
    };

enum ChallengeKind { code, textCaptcha, clickCaptcha, externalLogin }

class LogEntry {
  LogEntry(this.time, this.level, this.message);
  final DateTime time;
  final String level; // info | warning | error | debug
  final String message;
}

class IpResource {
  IpResource(this.ipMin, this.ipMax, this.portMin, this.portMax, this.protocol);
  final String ipMin, ipMax, protocol;
  final int portMin, portMax;

  String get range => ipMin == ipMax ? ipMin : '$ipMin – $ipMax';
  String get ports =>
      portMin == portMax ? '$portMin' : (portMin <= 1 && portMax >= 65535 ? '*' : '$portMin-$portMax');

  factory IpResource.fromJson(Map<String, dynamic> j) => IpResource(
        j['ip_min'] as String? ?? '',
        j['ip_max'] as String? ?? '',
        j['port_min'] as int? ?? 0,
        j['port_max'] as int? ?? 0,
        j['protocol'] as String? ?? '',
      );
}

class WebResource {
  WebResource(this.name, this.group, this.url, this.host);
  final String name, group, url, host;
  /// Stable identity for favorites: survives reordering of the rclist.
  String get favKey => '$name\u0000${url.isNotEmpty ? url : host}';
  factory WebResource.fromJson(Map<String, dynamic> j) => WebResource(
        j['name'] as String? ?? '',
        j['group'] as String? ?? '',
        j['url'] as String? ?? '',
        j['host'] as String? ?? '',
      );
}

class PortForwardInfo {
  PortForwardInfo(this.network, this.bind, this.remote);
  final String network, bind, remote;
}

class SessionInfo {
  SessionInfo({
    required this.protocol,
    required this.server,
    required this.ip,
    required this.dnsServer,
    required this.secondaryDns,
    required this.routes,
    required this.stack,
    required this.socksBind,
    required this.httpBind,
    required this.dnsServerBind,
    required this.shadowsocks,
    required this.portForwarding,
    required this.ipResources,
    required this.domainResources,
    required this.mtu,
    this.webResources = const [],
    this.rawResources = '',
  });

  final String protocol, server, ip, dnsServer, secondaryDns, stack;
  final String socksBind, httpBind, dnsServerBind;
  final bool shadowsocks;
  final List<String> routes;
  final List<PortForwardInfo> portForwarding;
  final List<IpResource> ipResources;
  final List<String> domainResources;
  final int mtu;
  final List<WebResource> webResources;
  final String rawResources;

  factory SessionInfo.fromJson(Map<String, dynamic> j) => SessionInfo(
        protocol: j['protocol'] as String? ?? '',
        server: j['server'] as String? ?? '',
        ip: j['ip'] as String? ?? '',
        dnsServer: j['dns_server'] as String? ?? '',
        secondaryDns: j['secondary_dns'] as String? ?? '',
        routes: (j['routes'] as List? ?? []).cast<String>(),
        stack: j['stack'] as String? ?? '',
        socksBind: j['socks_bind'] as String? ?? '',
        httpBind: j['http_bind'] as String? ?? '',
        dnsServerBind: j['dns_server_bind'] as String? ?? '',
        shadowsocks: j['shadowsocks'] as bool? ?? false,
        portForwarding: (j['port_forwarding'] as List? ?? [])
            .map((e) => PortForwardInfo(e['network'] as String? ?? '',
                e['bind'] as String? ?? '', e['remote'] as String? ?? ''))
            .toList(),
        ipResources: (j['ip_resources'] as List? ?? [])
            .map((e) => IpResource.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
        domainResources: ((j['domain_resources'] as List? ?? []).cast<String>()
              ..sort()),
        mtu: j['mtu'] as int? ?? 0,
        webResources: (j['web_resources'] as List? ?? [])
            .map((e) => WebResource.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
        rawResources: j['raw_resources'] as String? ?? '',
      );
}

class Challenge {
  Challenge({
    required this.id,
    required this.kind,
    required this.message,
    this.codeKind = '',
    this.canSkip = false,
    this.imagePath = '',
    this.loginUrl = '',
  });

  final int id;
  final ChallengeKind kind;
  final String message, codeKind, imagePath, loginUrl;
  final bool canSkip;

  factory Challenge.fromJson(Map<String, dynamic> j) => Challenge(
        id: (j['id'] as num).toInt(),
        kind: switch (j['kind']) {
          'text_captcha' => ChallengeKind.textCaptcha,
          'click_captcha' => ChallengeKind.clickCaptcha,
          'external_login' => ChallengeKind.externalLogin,
          _ => ChallengeKind.code,
        },
        message: j['message'] as String? ?? '',
        codeKind: j['code_kind'] as String? ?? '',
        canSkip: j['can_skip'] as bool? ?? false,
        imagePath: j['image_path'] as String? ?? '',
        loginUrl: j['login_url'] as String? ?? '',
      );
}

/// Answer for a [Challenge]; serialised as `response` of `challenge_response`.
class ChallengeAnswer {
  const ChallengeAnswer({
    this.cancel = false,
    this.code,
    this.skipSecondaryAuth = false,
    this.points,
    this.width,
    this.height,
    this.callbackUrl,
  });
  const ChallengeAnswer.cancelled() : this(cancel: true);

  final bool cancel;
  final String? code;
  final bool skipSecondaryAuth;
  final List<(int, int)>? points;
  final int? width, height;
  final String? callbackUrl;

  Map<String, dynamic> toJson() => {
        if (cancel) 'cancel': true,
        if (code != null) 'code': code,
        if (skipSecondaryAuth) 'skip_secondary_auth': true,
        if (points != null)
          'points': [for (final p in points!) {'x': p.$1, 'y': p.$2}],
        if (width != null) 'width': width,
        if (height != null) 'height': height,
        if (callbackUrl != null) 'callback_url': callbackUrl,
      };
}

/// Parsed stdout event.
sealed class CoreEvent {
  const CoreEvent();

  static CoreEvent? parse(Map<String, dynamic> j) {
    final t = j['type'];
    final time = j['time'] is int
        ? DateTime.fromMillisecondsSinceEpoch(j['time'] as int)
        : DateTime.now();
    switch (t) {
      case 'hello':
        return HelloEvent(j['version'] as String? ?? '');
      case 'log':
        return LogEvent(LogEntry(time, j['level'] as String? ?? 'info',
            j['message'] as String? ?? ''));
      case 'state':
        return StateEvent(coreStateFrom(j['state'] as String?), j['error'] as String?);
      case 'challenge':
        return ChallengeEvent(Challenge.fromJson(j));
      case 'session':
      case 'tun_request':
        final s = j['session'];
        if (s is Map) {
          return SessionEvent(SessionInfo.fromJson(s.cast<String, dynamic>()),
              tunRequest: t == 'tun_request');
        }
        return null;
      case 'flows':
        final l = j['flows'];
        return FlowsEvent(l is List
            ? l.whereType<Map>().map((e) => FlowInfo.fromJson(e.cast<String, dynamic>())).toList()
            : const []);
      case 'probe':
        final m = j['probe'];
        if (m is Map) {
          return ProbeEvent(
            m['host'] as String? ?? '',
            (m['port'] as num?)?.toInt() ?? 0,
            m['ok'] == true,
            (m['ms'] as num?)?.toInt() ?? 0,
            m['error'] as String?,
          );
        }
        return null;
      case 'traffic':
        final m = j['traffic'];
        if (m is Map) return TrafficEvent(TrafficStats.fromJson(m.cast<String, dynamic>()));
        return null;
      case 'proxy_status':
        return ProxyStatusEvent(j['ok'] == true, j['message'] as String? ?? '', j['error'] as String?);
      case 'detached':
        return DetachedEvent((j['port'] as num?)?.toInt() ?? 0, (j['pid'] as num?)?.toInt() ?? 0);
      case 'pong':
        return PongEvent(coreStateFrom(j['state'] as String?), (j['pid'] as num?)?.toInt() ?? 0);
      case 'auth_info':
      case 'result':
        return ResultEvent(j['ok'] == true, j['error'] as String?, j['auth_info']);
    }
    return null;
  }
}

class HelloEvent extends CoreEvent {
  const HelloEvent(this.version);
  final String version;
}

class LogEvent extends CoreEvent {
  const LogEvent(this.entry);
  final LogEntry entry;
}

class StateEvent extends CoreEvent {
  const StateEvent(this.state, this.error);
  final CoreState state;
  final String? error;
}

class ChallengeEvent extends CoreEvent {
  const ChallengeEvent(this.challenge);
  final Challenge challenge;
}

class SessionEvent extends CoreEvent {
  const SessionEvent(this.session, {this.tunRequest = false});
  final SessionInfo session;
  final bool tunRequest;
}

/// Where a connection went.
enum FlowRoute { vpn, direct, proxy, blocked }

/// One (destination, route) bucket of the connection topology.
class FlowInfo {
  const FlowInfo(this.host, this.route, this.conns, this.up, this.down);
  final String host;
  final FlowRoute route;
  final int conns;
  final int up;
  final int down;

  factory FlowInfo.fromJson(Map<String, dynamic> j) => FlowInfo(
        j['host'] as String? ?? '?',
        switch (j['route']) {
          'direct' => FlowRoute.direct,
          'proxy' => FlowRoute.proxy,
          'blocked' => FlowRoute.blocked,
          _ => FlowRoute.vpn,
        },
        (j['conns'] as num?)?.toInt() ?? 1,
        (j['up'] as num?)?.toInt() ?? 0,
        (j['down'] as num?)?.toInt() ?? 0,
      );
}

/// Bytes through the core (to/from the VPN server) since this connection
/// started, and the current rates in bytes/s.
class TrafficStats {
  const TrafficStats({this.tx = 0, this.rx = 0, this.txRate = 0, this.rxRate = 0, this.mem = 0});
  final int tx, rx, txRate, rxRate;

  /// Memory of the core process (RSS, bytes); 0 when unknown.
  final int mem;
  static const zero = TrafficStats();
  factory TrafficStats.fromJson(Map<String, dynamic> j) => TrafficStats(
        tx: (j['tx'] as num?)?.toInt() ?? 0,
        rx: (j['rx'] as num?)?.toInt() ?? 0,
        txRate: (j['tx_rate'] as num?)?.toInt() ?? 0,
        rxRate: (j['rx_rate'] as num?)?.toInt() ?? 0,
        mem: (j['mem'] as num?)?.toInt() ?? 0,
      );
}

/// "1.2 MB" style size.
String formatBytes(num b) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${i == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}

/// One connectivity test result.
class ProbeEvent extends CoreEvent {
  const ProbeEvent(this.host, this.port, this.ok, this.ms, this.error);
  final String host;
  final int port;
  final bool ok;
  final int ms;
  final String? error;
}

/// A host to test; port 0 = try 443 then 80.
class ProbeTarget {
  const ProbeTarget(this.host, [this.port = 0]);
  final String host;
  final int port;
  String get key => '$host#$port';
  Map<String, dynamic> toJson() => {'host': host, if (port > 0) 'port': port};

  /// From a URL or bare host[:port].
  static ProbeTarget? fromUrl(String url) {
    var u = url.trim();
    if (u.isEmpty) return null;
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(u)) u = 'http://$u';
    final uri = Uri.tryParse(u);
    if (uri == null || uri.host.isEmpty || RegExp(r'[*~]').hasMatch(uri.host)) return null;
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : (uri.scheme == 'http' ? 80 : 0));
    return ProbeTarget(uri.host, port);
  }

  /// A single-address IP resource; ranges are not tested.
  static ProbeTarget? fromIp(IpResource r) {
    if (r.ipMin.isEmpty || r.ipMin != r.ipMax || r.protocol == 'udp') return null;
    int port;
    if (r.portMin == r.portMax) {
      port = r.portMin;
    } else if (r.portMin <= 443 && r.portMax >= 443) {
      port = 0;
    } else if (r.portMin <= 80 && r.portMax >= 80) {
      port = 80;
    } else {
      port = r.portMin;
    }
    return port < 0 ? null : ProbeTarget(r.ipMin, port);
  }

  /// A domain resource; wildcards are not tested.
  static ProbeTarget? fromDomain(String d) {
    final h = d.trim();
    if (h.isEmpty || h.contains('*') || h.startsWith('.')) return null;
    return ProbeTarget(h);
  }
}

class TrafficEvent extends CoreEvent {
  const TrafficEvent(this.stats);
  final TrafficStats stats;
}

class FlowsEvent extends CoreEvent {
  const FlowsEvent(this.flows);
  final List<FlowInfo> flows;
}

/// External proxy went down (ok=false) or came back (ok=true).
class ProxyStatusEvent extends CoreEvent {
  const ProxyStatusEvent(this.ok, this.proxy, this.error);
  final bool ok;
  final String proxy;
  final String? error;
}

class ResultEvent extends CoreEvent {
  const ResultEvent(this.ok, this.error, this.authInfo);
  final bool ok;
  final String? error;
  final Object? authInfo;
}

/// Raw stderr line or a message produced by the app itself.
class RawLogEvent extends CoreEvent {
  const RawLogEvent(this.entry);
  final LogEntry entry;
}

/// The core process exited.
class ExitEvent extends CoreEvent {
  const ExitEvent(this.code);
  final int code;
}

/// Lightweight mode: the core keeps running without the UI and accepts
/// re-attaches on 127.0.0.1:[port].
class DetachedEvent extends CoreEvent {
  const DetachedEvent(this.port, this.pid);
  final int port;
  final int pid;
}

/// Answer to a re-attach "ping": the detached core is alive.
class PongEvent extends CoreEvent {
  const PongEvent(this.state, this.pid);
  final CoreState state;
  final int pid;
}
