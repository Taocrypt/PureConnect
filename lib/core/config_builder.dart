import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/profile.dart';
import '../models/settings.dart';
import 'extra_args.dart';

/// Builds the JSON config understood by zjuconnect-core. Keys are exactly the
/// snake_case keys of upstream zju-connect's config.toml.
Map<String, dynamic> buildCoreConfig({
  required Profile profile,
  required AppSettings settings,
  required String dataDir,
  required bool android,
  DateTime? now,
}) {
  final host = settings.allowLan ? '0.0.0.0' : '127.0.0.1';
  // Android VPN mode uses the platform TUN; desktop TUN uses upstream tun_mode.
  final tunDesktop = !android && settings.trafficMode == TrafficMode.tun;

  final c = <String, dynamic>{
    'protocol': profile.protocol.name,
    'server_address': profile.effectiveServer,
    'server_port': profile.serverPort,
    'username': profile.username,
    'password': profile.password,
    if (profile.totpSecret.isNotEmpty) 'totp_secret': profile.totpSecret,

    'socks_bind': settings.socksPort > 0 ? '$host:${settings.socksPort}' : '',
    'http_bind': settings.httpPort > 0 ? '$host:${settings.httpPort}' : '',
    if (settings.socksUser.isNotEmpty) 'socks_user': settings.socksUser,
    if (settings.socksPassword.isNotEmpty) 'socks_passwd': settings.socksPassword,
    if (settings.shadowsocksUrl.isNotEmpty) 'shadowsocks_url': settings.shadowsocksUrl,
    if (settings.dialDirectProxy.trim().isNotEmpty) 'dial_direct_proxy': settings.dialDirectProxy.trim(),
    // Read and removed by the Android VpnService before the core sees it.
    if (Platform.isAndroid && settings.dialDirectProxy.trim().isNotEmpty)
      'android_bypass_apps': settings.bypassApps,
    // Shown in the Android notification; removed by the VpnService.
    if (Platform.isAndroid) 'android_profile_label': profile.name,
    'proxy_all': settings.proxyAll,
    'tcp_tunnel_mode': settings.tcpTunnelMode,

    'disable_server_config': profile.disableServerConfig,
    'disable_remote_dns': settings.disableRemoteDns,
    'remote_dns_server': settings.remoteDnsServer.isEmpty ? 'auto' : settings.remoteDnsServer,
    'secondary_dns_server':
        settings.secondaryDnsServer.isEmpty ? 'auto' : settings.secondaryDnsServer,
    if (settings.localDnsServer.isNotEmpty) 'local_dns_server': settings.localDnsServer,
    if (settings.dnsServerBind.isNotEmpty) 'dns_server_bind': settings.dnsServerBind,
    'dns_ttl': settings.dnsTtl,
    'custom_dns': [
      for (final d in settings.customDns)
        if (d.host.isNotEmpty && d.ip.isNotEmpty) {'host_name': d.host, 'ip': d.ip}
    ],
    'port_forwarding': [
      for (final f in settings.portForwards)
        if (f.bind.isNotEmpty && f.remote.isNotEmpty)
          {'network_type': f.network, 'bind_address': f.bind, 'remote_address': f.remote}
    ],
    'disable_keep_alive': settings.disableKeepAlive,
    if (settings.keepAliveUrl.isNotEmpty) 'keep_alive_url': settings.keepAliveUrl,

    'tun_mode': tunDesktop,
    'add_route': settings.addRoute,
    'dns_hijack': tunDesktop && settings.dnsHijack,
    'fake_ip': tunDesktop && settings.fakeIp,

    if (settings.bindInterface.isNotEmpty) 'bind_interface': settings.bindInterface,
    'auto_detect_interface': settings.autoDetectInterface,
    'debug_dump': settings.debugDump,
    if (settings.debugPcap)
      'debug_pcap_file': p.join(debugDir(dataDir), '${_stamp(now)}.pcap'),
    if (settings.debugTlsKeyLog)
      'debug_tls_log_file': p.join(debugDir(dataDir), '${_stamp(now)}.keys.log'),
  };

  if (profile.protocol == VpnProtocol.easyconnect) {
    c.addAll({
      if (profile.certFile.isNotEmpty) 'cert_file': profile.certFile,
      if (profile.certPassword.isNotEmpty) 'cert_password': profile.certPassword,
      if (profile.twfId.isNotEmpty) 'twf_id': profile.twfId,
      // ZJU defaults (10.0.0.0/8, zju.edu.cn domains) only make sense on ZJU's
      // own servers; on other schools they route traffic the server rejects,
      // which makes it SHUTDOWN the whole tunnel.
      'disable_zju_config': profile.disableZjuConfig || !profile.isZjuHost,
      'skip_domain_resource': profile.skipDomainResource,
      'disable_multi_line': profile.disableMultiLine,
      'custom_proxy_domain': settings.customProxyDomains.where((d) => d.isNotEmpty).toList(),
    });
  } else {
    c.addAll({
      if (profile.authType.value.isNotEmpty) 'auth_type': profile.authType.value,
      if (profile.phone.isNotEmpty) 'phone': profile.phone,
      'login_domain': profile.loginDomain.isEmpty ? 'Radius' : profile.loginDomain,
      if (profile.casTicket.isNotEmpty) 'cas_ticket': profile.casTicket,
      if (profile.oauth2Code.isNotEmpty) 'oauth2_code': profile.oauth2Code,
      if (profile.saveClientData)
        'client_data_file': p.join(dataDir, 'atrust-${profile.id}.json'),
      if (profile.macAddresses.isNotEmpty) 'mac_addresses': profile.macAddresses,
      'update_best_nodes_interval': settings.updateBestNodesInterval,
      'session_refresh_interval': settings.sessionRefreshInterval,
    });
  }
  // Extra options typed by the user win over the app's own values; invalid
  // ones are reported before connecting (CoreController.connect).
  if (settings.extraArgs.trim().isNotEmpty) parseExtraArgs(settings.extraArgs).applyTo(c);
  return c;
}

/// Where PCAP / TLS key-log files go (one pair per connection).
String debugDir(String dataDir) => p.join(dataDir, 'debug');

String _stamp(DateTime? now) {
  final t = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return 'pureconnect-${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
}

/// Where the aTrust client data of [profile] is persisted.
File clientDataFile(String dataDir, Profile profile) =>
    File(p.join(dataDir, 'atrust-${profile.id}.json'));
