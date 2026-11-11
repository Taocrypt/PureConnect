import 'package:flutter/widgets.dart';

/// Maps raw zjuconnect-core / server errors to a readable message in the
/// app's language.
///
/// The rule table was built from every `errors.New` / `fmt.Errorf` string in
/// the upstream client and our bridge (see test/fixtures/core_errors.txt,
/// regenerate it when the core is upgraded). Rules are tried in order on the
/// whole lower-cased error chain; the first match wins. Anything unmatched
/// falls back to "Connection failed: (innermost cause)", never raw XML.

class ErrorRule {
  const ErrorRule(this.key, this.pattern, {this.withDetail = false});
  final String key;
  final RegExp pattern;

  /// Append the server's own message (when there is one) after ours.
  final bool withDetail;
}

RegExp _r(String p) => RegExp(p, caseSensitive: false);

final errorRules = <ErrorRule>[
  // Same account signed in elsewhere (core: session_guard.go). First, so
  // the "handshake reply" inside it never reads as a generic tunnel error.
  ErrorRule('kicked', _r(r'kicked offline')),
  // --- user action ---
  ErrorRule('elevation_cancelled', _r(r'administrator authorization cancelled')),
  ErrorRule('wintun_missing', _r(r'wintun\.dll')),
  ErrorRule('cancelled', _r(r'cancelled by user|authentication denied')),
  // --- login / credentials ---
  ErrorRule('bruteforce', _r(r'brute-?force|word verification is enabled|登录.*频繁|尝试次数过多')),
  ErrorRule('bad_password', _r(r'invalid username or password|用户名或密码|密码错误')),
  ErrorRule('captcha_wrong', _r(r'rand ?code|captcha verification failed|invalid easyconnect captcha|invalid click captcha|验证码错误|图形验证码')),
  ErrorRule('captcha_error', _r(r'captcha (image|server|response|output)|text captcha|image (data|dimensions|size)|invalid dimensions|invalid coordinates|click captcha')),
  ErrorRule('challenge_timeout', _r(r'timed out after|input timed out|auth timeout')),
  ErrorRule('code_empty', _r(r'captcha code is empty|response is empty|authentication code is empty|sms code required|totp required|callback url is empty|ticket is empty')),
  ErrorRule('sms_failed', _r(r'sms code verification failed|smscheckcode|authsms|sendsms|sendcustomsms|customsmscheckcode|sms authentication|phonenumber|sms challenge|unknown sms'), withDetail: true),
  ErrorRule('totp_failed', _r(r'totp')),
  ErrorRule('radius_failed', _r(r'radius')),
  ErrorRule('trusted_device', _r(r'trusted device|bindauthdevice|trustdevice|untrustdevice|querydevice|client data'), withDetail: true),
  ErrorRule('locked', _r(r'locked|锁定|冻结')),
  ErrorRule('account_disabled', _r(r'disabled user|user (is |has been )?disabled|account.*(disabled|expired)|禁用|过期|停用')),
  ErrorRule('too_many_online', _r(r'max(imum)? online|online users|在线人数|已在其他')),
  ErrorRule('missing_credentials', _r(r'missing credentials|username and password are required')),
  ErrorRule('auth_type', _r(r'auth type/login domain|unsupported auth type|login method is nil')),
  ErrorRule('unsupported_auth', _r(r'unsupported (next|enhanced|token) authentication|unsupported .*challenge|unsupported click captcha|not implemented auth|authentication chain exceeded|token authentication type is missing|external login')),
  ErrorRule('external_login', _r(r'invalid (callback|redirect) url|invalid portal data')),
  ErrorRule('session_expired', _r(r'session is invalid|reauthentication required|refresh rejected|token is nil')),
  ErrorRule('auth_failed', _r(r'(authcheck|accesscheck|authconfig|token authentication|reportenv|onlineinfo) failed|authconfig (http|response)|auth status|succeeded without a ticket|password authentication|login failed'), withDetail: true),
  ErrorRule('challenge_failed', _r(r'complete [a-z ]+ challenge')),
  ErrorRule('auth_failed', _r(r'failed with code|invalid status code|unexpected sms response'), withDetail: true),
  // --- server / tunnel ---
  ErrorRule('crypto', _r(r'rsa public key|sign key|tls key log')),
  ErrorRule('cert', _r(r'anti-mitm|cert verification|server certificate|cert required|x509|certificate')),
  ErrorRule('shutdown', _r(r'shutdown')),
  ErrorRule('reconnect_later', _r(r'reconnect_later')),
  ErrorRule('no_node', _r(r'no available line|no reachable node|no available .*node|disable mline|no mline|server manifest')),
  ErrorRule('resources', _r(r'no rcs element|resources? (not available|not found)|read resource file|dns servers? (not available|invalid)|no dns |ip (set )?not available|no list attribute|empty line list|no vpn resources|is not resource')),
  ErrorRule('tunnel', _r(r'l3[- ]tunnel|tcp tunnel|ip tunnel|update_session|tunnel closed|vip|request ip reply|handshake reply|ecagent|tls write failed|l3 tunnel|payload|packet|meta |meta$|checksum|conntrack|ip version|ipv4|udp dial|not supported|not implemented|stop after capturing')),
  // --- network ---
  ErrorRule('dns', _r(r'no such host|server misbehaving|lookup .*: ')),
  ErrorRule('port_in_use', _r(r'address already in use|only one usage of each socket address')),
  ErrorRule('network', _r(r'i/o timeout|deadline exceeded|connection refused|network is unreachable|host is unreachable|connection reset|broken pipe|dial failed|failed to connect|temporary network error|tls: |handshake failure|unexpected eof|offline|dial tcp')),
  // --- local setup ---
  ErrorRule('front_proxy', _r(r'front proxy')),
  ErrorRule('tun_permission', _r(r'using sudo|run as root|tun stack setup|needs administrator rights|needs root')),
  ErrorRule('vpn_setup', _r(r'tun fd|file descriptor|tun_fd_socket|android_fd|tun_mode|virtual ip|nic |gvisor|stack setup')),
  ErrorRule('vpn_permission', _r(r'vpn permission|not prepared')),
  ErrorRule('stop_failed', _r(r'listener failed')),
  ErrorRule('config', _r(r'config|load defaults|invalid vpn server port|unsupported (vpn )?protocol|port forwarding|custom dns|is not a valid domain|invalid host|bind interface|underlay')),
  ErrorRule('core_crashed', _r(r'core exited|panic')),
];

const _messages = <String, Map<String, String>>{
  'zh': {
    'elevation_cancelled': '已取消管理员授权，TUN 模式未开启',
    'wintun_missing': '缺少 wintun.dll，请重新安装 PureConnect',
    'cancelled': '已取消登录',
    'bruteforce': '登录失败次数过多，服务器已开启图形验证码。请检查账号密码后重新连接，并输入验证码',
    'bad_password': '用户名或密码错误，请检查配置后重试',
    'captcha_wrong': '验证码错误，请重新连接获取新的验证码',
    'challenge_timeout': '验证超时，请重新连接',
    'captcha_error': '验证码加载或提交失败，请重新连接',
    'challenge_failed': '二次验证未完成，请重新连接',
    'crypto': '与服务器协商加密失败',
    'stop_failed': '断开时释放本地端口失败，可重启应用',
    'code_empty': '没有填写验证码',
    'sms_failed': '短信验证失败',
    'totp_failed': 'TOTP 动态码验证失败，请检查密钥或手机时间',
    'radius_failed': 'RADIUS 动态码验证失败',
    'trusted_device': '可信设备验证失败',
    'locked': '账号已被服务器临时锁定，请稍后再试',
    'account_disabled': '账号已被禁用或已过期',
    'too_many_online': '该账号在线设备数已达上限',
    'kicked': '账号已在其他设备登录，本机已被挤下线',
    'missing_credentials': '配置缺少当前认证方式所需的用户名或密码',
    'auth_type': '服务器不支持所选的认证方式或登录域，请检查配置',
    'unsupported_auth': '服务器要求的认证方式暂不支持',
    'external_login': '浏览器登录的回调地址无效，请重新登录并粘贴完整地址',
    'session_expired': '会话已失效，请重新连接',
    'auth_failed': '服务器拒绝了登录',
    'cert': '服务器证书校验失败，网络可能被劫持',
    'shutdown': '服务器断开了会话，请重连或查看日志',
    'reconnect_later': '服务器繁忙，请稍后重连',
    'no_node': '服务器没有可用的线路或节点',
    'resources': '获取服务器资源列表失败',
    'tunnel': '建立隧道失败，请重连',
    'dns': '无法解析 VPN 服务器地址，请检查服务器地址和网络',
    'port_in_use': '本地代理端口被占用，请在设置中更换端口',
    'network': '无法连接 VPN 服务器，请检查网络',
    'front_proxy': '外部代理不可用，请检查外部代理地址',
    'tun_permission': 'TUN 模式需要管理员权限',
    'vpn_setup': '创建 VPN 虚拟网卡失败',
    'vpn_permission': '未授予 VPN 权限',
    'config': '配置有误',
    'core_crashed': '内核意外退出，请查看日志',
    'generic': '连接失败',
    'server_says': '服务器提示',
  },
  'en': {
    'elevation_cancelled': 'Administrator authorization cancelled; TUN mode not started',
    'wintun_missing': 'wintun.dll is missing. Reinstall PureConnect',
    'cancelled': 'Login cancelled',
    'bruteforce': 'Too many failed logins, so the server now requires a captcha. Check your username and password, then connect again and enter the captcha',
    'bad_password': 'Wrong username or password. Check the profile and try again',
    'captcha_wrong': 'Wrong captcha. Connect again to get a new one',
    'challenge_timeout': 'Verification timed out. Connect again',
    'captcha_error': 'Could not load or submit the captcha. Connect again',
    'challenge_failed': 'Second-step verification did not complete. Connect again',
    'crypto': 'Encryption negotiation with the server failed',
    'stop_failed': 'Could not release local ports while disconnecting. Restart the app if needed',
    'code_empty': 'No verification code was entered',
    'sms_failed': 'SMS verification failed',
    'totp_failed': 'TOTP verification failed. Check the secret and your phone\'s clock',
    'radius_failed': 'RADIUS code verification failed',
    'trusted_device': 'Trusted device verification failed',
    'locked': 'The account is temporarily locked by the server. Try later',
    'account_disabled': 'The account is disabled or expired',
    'too_many_online': 'This account has reached its online device limit',
    'kicked': 'This account signed in on another device; this device was signed out',
    'missing_credentials': 'The profile is missing the username or password this sign-in method needs',
    'auth_type': 'The server does not offer the selected sign-in method or login domain. Check the profile',
    'unsupported_auth': 'The server asked for a sign-in method that is not supported yet',
    'external_login': 'The browser sign-in callback URL is invalid. Sign in again and paste the full URL',
    'session_expired': 'The session expired. Connect again',
    'auth_failed': 'The server rejected the login',
    'cert': 'Server certificate check failed; the network may be intercepted',
    'shutdown': 'The server closed the session. Reconnect, or check the logs',
    'reconnect_later': 'The server is busy. Reconnect later',
    'no_node': 'The server has no available line or node',
    'resources': 'Could not get the resource list from the server',
    'tunnel': 'Could not set up the tunnel. Reconnect',
    'dns': 'Cannot resolve the VPN server address. Check the address and your network',
    'port_in_use': 'A local proxy port is already in use. Change it in Settings',
    'network': 'Cannot reach the VPN server. Check your network',
    'front_proxy': 'The external proxy is unreachable. Check its address',
    'tun_permission': 'TUN mode needs administrator rights',
    'vpn_setup': 'Could not create the VPN interface',
    'vpn_permission': 'VPN permission was denied',
    'config': 'The configuration is invalid',
    'core_crashed': 'The core exited unexpectedly. Check the logs',
    'generic': 'Connection failed',
    'server_says': 'Server says',
  },
};

final _wrappers = _r(
    r'^(vpn client setup error|complete [a-z ]+ challenge|configure atrust login|login failed|failed to connect to atrust server|open l3 tunnel|create underlay dialer|parse config|load config|decode config|tcp tunnel stack setup error|gvisor stack setup error|front proxy stack|refresh rejected)\s*:\s*');

/// The server's own human text, if the error carries one.
String? serverMessage(String raw) {
  final note = RegExp(r'<Note>\s*(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?\s*</Note>', dotAll: true).firstMatch(raw);
  if (note != null && note.group(1)!.trim().isNotEmpty) return note.group(1)!.trim();
  final coded = RegExp(r'failed with code -?\d+: (.+)$').firstMatch(raw);
  if (coded != null && coded.group(1)!.trim().isNotEmpty) return coded.group(1)!.trim();
  final login = RegExp(r'Login failed: (?!<)(.+)$').firstMatch(raw);
  if (login != null) return login.group(1)!.trim();
  return null;
}

/// Innermost cause with wrapper prefixes and markup removed.
String errorRoot(String raw) {
  var s = raw.trim();
  final msg = serverMessage(s);
  if (msg != null) return msg;
  for (var i = 0; i < 8; i++) {
    final m = _wrappers.firstMatch(s);
    if (m == null) break;
    s = s.substring(m.end);
  }
  s = s.replaceAll(RegExp(r'<[^>]+>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.length > 160) s = '${s.substring(0, 157)}…';
  return s;
}

/// Rule key for [raw], or null when nothing matched.
String? errorKey(String raw) {
  for (final r in errorRules) {
    if (r.pattern.hasMatch(raw)) return r.key;
  }
  return null;
}

/// Readable message in [lang] ('zh' or 'en').
String humanizeErrorIn(String lang, String raw) {
  final m = _messages[lang == 'zh' ? 'zh' : 'en']!;
  final key = errorKey(raw);
  final colon = lang == 'zh' ? '：' : ': ';
  if (key == null) return '${m['generic']}$colon${errorRoot(raw)}';
  final rule = errorRules.firstWhere((r) => r.key == key);
  var text = m[key]!;
  if (rule.withDetail) {
    final detail = serverMessage(raw);
    if (detail != null && detail.isNotEmpty && !detail.toLowerCase().contains('xml')) {
      text = '$text（${m['server_says']}$colon$detail）';
      if (lang != 'zh') text = text.replaceAll('（', ' (').replaceAll('）', ')');
    }
  }
  return text;
}

String humanizeError(BuildContext context, String raw) {
  final l = Localizations.maybeLocaleOf(context)?.languageCode ?? 'en';
  return humanizeErrorIn(l, raw);
}
