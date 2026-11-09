/// "Extra core options": zju-connect command-line style flags typed by the
/// user (e.g. `-disable-multi-line -dns-ttl 600`), turned into the snake_case
/// config keys the core takes (`disable_multi_line`, `dns_ttl`) and laid over
/// the config the app builds.
///
/// Flag names follow upstream zju-connect's CLI; one or two leading dashes,
/// `-flag value` or `-flag=value`; spaces or new lines separate options and
/// double quotes keep a value with spaces together. The list collections take
/// upstream's comma formats and are appended to the app's own lists.
library;

enum _Kind { string, boolean, integer }

const _flags = <String, (String, _Kind)>{
  'protocol': ('protocol', _Kind.string),
  'server': ('server_address', _Kind.string),
  'port': ('server_port', _Kind.integer),
  'username': ('username', _Kind.string),
  'password': ('password', _Kind.string),
  'totp-secret': ('totp_secret', _Kind.string),
  'cert-file': ('cert_file', _Kind.string),
  'cert-password': ('cert_password', _Kind.string),
  'disable-server-config': ('disable_server_config', _Kind.boolean),
  'skip-domain-resource': ('skip_domain_resource', _Kind.boolean),
  'disable-zju-config': ('disable_zju_config', _Kind.boolean),
  'disable-remote-dns': ('disable_remote_dns', _Kind.boolean),
  'disable-zju-dns': ('disable_remote_dns', _Kind.boolean),
  'disable-multi-line': ('disable_multi_line', _Kind.boolean),
  'proxy-all': ('proxy_all', _Kind.boolean),
  'socks-bind': ('socks_bind', _Kind.string),
  'socks-user': ('socks_user', _Kind.string),
  'socks-passwd': ('socks_passwd', _Kind.string),
  'http-bind': ('http_bind', _Kind.string),
  'shadowsocks-url': ('shadowsocks_url', _Kind.string),
  'dial-direct-proxy': ('dial_direct_proxy', _Kind.string),
  'tcp-tunnel-mode': ('tcp_tunnel_mode', _Kind.boolean),
  'add-route': ('add_route', _Kind.boolean),
  'dns-ttl': ('dns_ttl', _Kind.integer),
  'debug-dump': ('debug_dump', _Kind.boolean),
  'debug-pcap-file': ('debug_pcap_file', _Kind.string),
  'debug-tls-log-file': ('debug_tls_log_file', _Kind.string),
  'disable-keep-alive': ('disable_keep_alive', _Kind.boolean),
  'keep-alive-url': ('keep_alive_url', _Kind.string),
  'remote-dns-server': ('remote_dns_server', _Kind.string),
  'zju-dns-server': ('remote_dns_server', _Kind.string),
  'secondary-dns-server': ('secondary_dns_server', _Kind.string),
  'dns-server-bind': ('dns_server_bind', _Kind.string),
  'local-dns-server': ('local_dns_server', _Kind.string),
  'dns-hijack': ('dns_hijack', _Kind.boolean),
  'fake-ip': ('fake_ip', _Kind.boolean),
  'graph-code-file': ('graph_code_file', _Kind.string),
  'bind-interface': ('bind_interface', _Kind.string),
  'auto-detect-interface': ('auto_detect_interface', _Kind.boolean),
  'twf-id': ('twf_id', _Kind.string),
  'auth-type': ('auth_type', _Kind.string),
  'phone': ('phone', _Kind.string),
  'login-domain': ('login_domain', _Kind.string),
  'client-data-file': ('client_data_file', _Kind.string),
  'cas-ticket': ('cas_ticket', _Kind.string),
  'oauth2-code': ('oauth2_code', _Kind.string),
  'sid': ('sid', _Kind.string),
  'device-id': ('device_id', _Kind.string),
  'sign-key': ('sign_key', _Kind.string),
  'resource-file': ('resource_file', _Kind.string),
  'update-best-nodes-interval': ('update_best_nodes_interval', _Kind.integer),
  'session-refresh-interval': ('session_refresh_interval', _Kind.integer),
};

/// Flags the app drives itself (mode switch, one-shot commands).
const _managed = {'tun-mode', 'config', 'version', 'auth-info', 'trust-device', 'untrust-device', 'help'};

const _collections = {'tcp-port-forwarding', 'udp-port-forwarding', 'custom-dns', 'custom-proxy-domain'};

class ExtraArgs {
  ExtraArgs(this.config, this.portForwarding, this.customDns, this.proxyDomains, this.errors);

  /// Scalar overrides by config key.
  final Map<String, Object> config;
  final List<Map<String, String>> portForwarding;
  final List<Map<String, String>> customDns;
  final List<String> proxyDomains;

  /// Human-readable problems (unknown flag, missing / bad value).
  final List<String> errors;

  bool get isEmpty =>
      config.isEmpty && portForwarding.isEmpty && customDns.isEmpty && proxyDomains.isEmpty;

  /// Lays the options over [c] (the config from buildCoreConfig).
  void applyTo(Map<String, dynamic> c) {
    c.addAll(config);
    if (portForwarding.isNotEmpty) {
      c['port_forwarding'] = [...(c['port_forwarding'] as List? ?? const []), ...portForwarding];
    }
    if (customDns.isNotEmpty) {
      c['custom_dns'] = [...(c['custom_dns'] as List? ?? const []), ...customDns];
    }
    if (proxyDomains.isNotEmpty) {
      c['custom_proxy_domain'] = [...(c['custom_proxy_domain'] as List? ?? const []), ...proxyDomains];
    }
  }
}

/// Splits on whitespace; "double quoted" parts keep their spaces.
List<String> tokenizeArgs(String text) {
  final out = <String>[];
  final cur = StringBuffer();
  var quoted = false;
  var has = false;
  for (final ch in text.runes.map(String.fromCharCode)) {
    if (ch == '"') {
      quoted = !quoted;
      has = true;
    } else if (!quoted && ch.trim().isEmpty) {
      if (has) out.add(cur.toString());
      cur.clear();
      has = false;
    } else {
      cur.write(ch);
      has = true;
    }
  }
  if (has) out.add(cur.toString());
  return out;
}

ExtraArgs parseExtraArgs(String text) {
  final config = <String, Object>{};
  final pf = <Map<String, String>>[];
  final dns = <Map<String, String>>[];
  final domains = <String>[];
  final errors = <String>[];
  final tokens = tokenizeArgs(text);
  for (var i = 0; i < tokens.length; i++) {
    final tok = tokens[i];
    if (!tok.startsWith('-') || tok == '-' || tok == '--') {
      errors.add('unexpected value "$tok"');
      continue;
    }
    var name = tok.replaceFirst(RegExp('^--?'), '');
    String? value;
    final eq = name.indexOf('=');
    if (eq >= 0) {
      value = name.substring(eq + 1);
      name = name.substring(0, eq);
    }
    bool nextIsValue() => i + 1 < tokens.length && !RegExp(r'^--?[a-zA-Z]').hasMatch(tokens[i + 1]);
    String? takeValue() {
      if (value != null) return value;
      if (nextIsValue()) return tokens[++i];
      return null;
    }

    if (_managed.contains(name)) {
      errors.add('-$name is set by the app');
      if (value == null && nextIsValue() && !_flags.containsKey(name)) i++;
      continue;
    }
    if (_collections.contains(name)) {
      final v = takeValue();
      if (v == null || v.isEmpty) {
        errors.add('-$name needs a value');
        continue;
      }
      for (final item in v.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty)) {
        switch (name) {
          case 'tcp-port-forwarding' || 'udp-port-forwarding':
            final at = item.indexOf('-');
            if (at <= 0 || at == item.length - 1) {
              errors.add('-$name: "$item" is not bind-remote');
            } else {
              pf.add({
                'network_type': name.startsWith('tcp') ? 'tcp' : 'udp',
                'bind_address': item.substring(0, at),
                'remote_address': item.substring(at + 1),
              });
            }
          case 'custom-dns':
            final at = item.indexOf(':');
            if (at <= 0 || at == item.length - 1) {
              errors.add('-custom-dns: "$item" is not host:ip');
            } else {
              dns.add({'host_name': item.substring(0, at), 'ip': item.substring(at + 1)});
            }
          default:
            domains.add(item);
        }
      }
      continue;
    }
    final spec = _flags[name];
    if (spec == null) {
      errors.add('unknown option -$name');
      if (value == null && nextIsValue()) i++;
      continue;
    }
    final (key, kind) = spec;
    switch (kind) {
      case _Kind.boolean:
        var v = value;
        if (v == null && nextIsValue() && RegExp(r'^(true|false)$', caseSensitive: false).hasMatch(tokens[i + 1])) {
          v = tokens[++i];
        }
        if (v == null) {
          config[key] = true;
        } else if (RegExp(r'^(true|1)$', caseSensitive: false).hasMatch(v)) {
          config[key] = true;
        } else if (RegExp(r'^(false|0)$', caseSensitive: false).hasMatch(v)) {
          config[key] = false;
        } else {
          errors.add('-$name expects true or false');
        }
      case _Kind.integer:
        final v = takeValue();
        final n = int.tryParse(v ?? '');
        if (n == null) {
          errors.add('-$name expects a number');
        } else {
          config[key] = n;
        }
      case _Kind.string:
        final v = takeValue();
        if (v == null) {
          errors.add('-$name needs a value');
        } else {
          config[key] = v;
        }
    }
  }
  return ExtraArgs(config, pf, dns, domains, errors);
}
