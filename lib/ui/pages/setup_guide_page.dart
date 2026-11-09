import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../l10n/strings.dart';
import '../../models/profile.dart';
import '../../state/providers.dart';
import '../kit/app_glyphs.dart';
import '../kit/common.dart';
import '../kit/dashboard_kit.dart';

/// One sign-in method the aTrust server offers (`-auth-info`).
class GuideAuthOption {
  const GuideAuthOption(this.authType, this.loginDomain, this.name);
  final String authType;
  final String loginDomain;
  final String name;

  /// Parses the core's auth_info list; unknown shapes give an empty list.
  static List<GuideAuthOption> parse(Object? info) {
    final out = <GuideAuthOption>[];
    if (info is! List) return out;
    for (final e in info) {
      if (e is! Map) continue;
      final type = '${e['authType'] ?? ''}';
      if (type.isEmpty) continue;
      out.add(GuideAuthOption(type, '${e['loginDomain'] ?? ''}', '${e['authName'] ?? ''}'));
    }
    return out;
  }
}

/// Step-by-step first profile: protocol → server → sign-in method →
/// credentials. Saves a normal profile (editable later) and selects it.
class SetupGuidePage extends ConsumerStatefulWidget {
  const SetupGuidePage({super.key});

  @override
  ConsumerState<SetupGuidePage> createState() => _SetupGuidePageState();
}

class _SetupGuidePageState extends ConsumerState<SetupGuidePage> {
  static const _steps = 4;
  int _step = 0;
  final p = Profile(name: '', disableZjuConfig: true);
  final _server = TextEditingController();
  final _port = TextEditingController(text: '443');
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _totp = TextEditingController();
  final _phone = TextEditingController();
  final _certPass = TextEditingController();
  bool _cert = false; // EasyConnect: certificate instead of password
  bool _busy = false;
  bool _show = false;
  List<GuideAuthOption>? _options;
  String? _fetchError;

  @override
  void dispose() {
    for (final c in [_server, _port, _user, _pass, _totp, _phone, _certPass]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _atrust => p.protocol == VpnProtocol.atrust;

  bool get _needsPassword =>
      _atrust ? (p.authType == AtrustAuthType.password || p.authType == AtrustAuthType.auto) : !_cert;

  String _authLabel(AtrustAuthType t) => switch (t) {
        AtrustAuthType.auto => context.tr('auto'),
        AtrustAuthType.password => context.tr('password'),
        AtrustAuthType.sms => context.tr('challenge_sms'),
        AtrustAuthType.cas => 'CAS',
        AtrustAuthType.oauth2 => 'OAuth2',
      };

  Future<void> _fetch() async {
    setState(() {
      _busy = true;
      _fetchError = null;
    });
    final r = await ref.read(coreProvider.notifier).fetchAuthInfo(p);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r.ok) {
        _options = GuideAuthOption.parse(r.authInfo);
      } else {
        _fetchError = r.error ?? 'error';
      }
    });
  }

  /// Checks the current step; returns an error text or null.
  String? _check() {
    switch (_step) {
      case 1:
        final host = _server.text.trim();
        final port = int.tryParse(_port.text.trim());
        if (host.isEmpty || host.contains(' ') || host.contains('/')) return context.tr('guide_bad_server');
        if (port == null || port < 1 || port > 65535) return '${context.tr('server_port')}: 1-65535';
        p.serverAddress = host;
        p.serverPort = port;
      case 3:
        if (_needsPassword && (_user.text.trim().isEmpty || _pass.text.isEmpty) && p.authType != AtrustAuthType.auto) {
          return context.tr('guide_need_password');
        }
        if (_atrust && p.authType == AtrustAuthType.sms && _phone.text.trim().isEmpty) return context.tr('guide_need_phone');
        if (!_atrust && _cert && p.certFile.isEmpty) return context.tr('guide_need_cert');
    }
    return null;
  }

  void _next() {
    final err = _check();
    if (err != null) {
      showToast(context, err, level: BannerLevel.warning);
      return;
    }
    if (_step < _steps - 1) {
      setState(() => _step++);
      return;
    }
    p.username = _user.text.trim();
    p.password = _pass.text;
    p.totpSecret = _totp.text.trim();
    p.phone = _phone.text.trim();
    p.certPassword = _cert ? _certPass.text : '';
    if (!_cert) p.certFile = '';
    p.name = p.serverAddress;
    ref.read(profilesProvider.notifier).upsert(p);
    ref.read(settingsProvider.notifier).update((s) {
      s.selectedProfileId = p.id;
      s.setupGuideShown = true;
    });
    showToast(context, context.tr('guide_done'), level: BannerLevel.success);
    Navigator.of(context).pop();
  }

  Widget _field(String label, TextEditingController c, {String? hint, bool secret = false, TextInputType? type}) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 8, children: [
          Text(label, style: DashboardText.label(context)),
          TextField(
            controller: c,
            obscureText: secret && !_show,
            keyboardType: type,
            autocorrect: false,
            decoration: InputDecoration(
              hintText: hint,
              suffixIcon: secret
                  ? IconButton(
                      tooltip: context.tr(_show ? 'hide_password' : 'show_password'),
                      onPressed: () => setState(() => _show = !_show),
                      icon: GlyphIcon(_show ? AppGlyphs.eyeOff : AppGlyphs.eye, size: 20),
                    )
                  : null,
            ),
          ),
        ]),
      );

  Widget _choice(String title, String? subtitle, bool selected, VoidCallback onTap) => SettingsTile(
        title: title,
        subtitle: subtitle,
        trailing: selected ? GlyphIcon(AppGlyphs.check, size: 20, color: context.colorScheme.primary) : null,
        onTap: onTap,
      );

  List<Widget> _body() {
    switch (_step) {
      case 0:
        return [
          SettingsGroup(title: context.tr('guide_protocol'), footer: context.tr('guide_protocol_hint'), children: [
            _choice('aTrust', context.tr('guide_atrust_desc'), _atrust, () => setState(() => p.protocol = VpnProtocol.atrust)),
            _choice('EasyConnect', context.tr('guide_ec_desc'), !_atrust,
                () => setState(() => p.protocol = VpnProtocol.easyconnect)),
          ]),
        ];
      case 1:
        return [
          SettingsGroup(title: context.tr('guide_server'), footer: context.tr('guide_server_hint'), children: [
            _field(context.tr('server_address'), _server,
                hint: _atrust ? 'vpn.xxx.edu.cn' : 'xvpn.xxx.edu.cn', type: TextInputType.url),
            _field(context.tr('server_port'), _port, type: TextInputType.number),
          ]),
        ];
      case 2:
        if (!_atrust) {
          return [
            SettingsGroup(title: context.tr('guide_auth'), children: [
              _choice(context.tr('guide_auth_password'), null, !_cert, () => setState(() => _cert = false)),
              _choice(context.tr('cert_file'), context.tr('guide_cert_desc'), _cert, () => setState(() => _cert = true)),
            ]),
          ];
        }
        return [
          SettingsGroup(title: context.tr('guide_auth'), footer: context.tr('guide_auth_hint'), children: [
            SettingsTile(
              glyph: AppGlyphs.search,
              title: context.tr('fetch_auth_info'),
              trailing: _busy ? const ActivityIndicator(size: 18) : null,
              chevron: !_busy,
              onTap: _busy ? null : _fetch,
            ),
            if (_fetchError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Text(_fetchError!, style: DashboardText.label(context, color: context.colorScheme.error)),
              ),
            for (final o in _options ?? const <GuideAuthOption>[])
              _choice(
                o.name.isEmpty ? o.authType : o.name,
                [o.authType, if (o.loginDomain.isNotEmpty) o.loginDomain].join(' · '),
                p.authType.value == o.authType && p.loginDomain == o.loginDomain,
                () => setState(() {
                  p.authType = AtrustAuthType.fromValue(o.authType);
                  if (o.loginDomain.isNotEmpty) p.loginDomain = o.loginDomain;
                }),
              ),
          ]),
          SettingsGroup(title: context.tr('guide_auth_manual'), children: [
            for (final t in AtrustAuthType.values)
              _choice(_authLabel(t), t.value.isEmpty ? null : t.value, p.authType == t, () => setState(() => p.authType = t)),
          ]),
        ];
      default:
        final browser = _atrust && (p.authType == AtrustAuthType.cas || p.authType == AtrustAuthType.oauth2);
        return [
          SettingsGroup(title: context.tr('guide_credentials'), footer: browser ? context.tr('guide_browser_login') : null, children: [
            if (_needsPassword) ...[
              _field(context.tr('username'), _user),
              _field(context.tr('password'), _pass, secret: true),
            ],
            if (_atrust && p.authType == AtrustAuthType.sms) _field(context.tr('phone'), _phone, type: TextInputType.phone),
            if (!_atrust && _cert) ...[
              SettingsTile(
                title: context.tr('cert_file'),
                subtitle: p.certFile.isEmpty ? '—' : p.certFile,
                chevron: true,
                onTap: () async {
                  final r = await FilePicker.pickFiles(type: FileType.any);
                  final path = r.isEmpty ? null : r.first.path;
                  if (path != null) setState(() => p.certFile = path);
                },
              ),
              _field(context.tr('cert_password'), _certPass, secret: true),
            ],
            if (!browser) _field('${context.tr('totp_secret')} (${context.tr('optional')})', _totp, secret: true),
          ]),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final last = _step == _steps - 1;
    return AppPage(
      canPop: true,
      title: context.tr('setup_guide'),
      body: PageList(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
          child: Text(context.tr('guide_step', {'n': '${_step + 1}', 'total': '$_steps'}), style: DashboardText.label(context)),
        ),
        ..._body(),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(mainAxisAlignment: MainAxisAlignment.end, spacing: 8, children: [
            if (_step > 0) TextButton(onPressed: () => setState(() => _step--), child: Text(context.tr('guide_back'))),
            FilledButton(onPressed: _next, child: Text(context.tr(last ? 'save' : 'guide_next'))),
          ]),
        ),
      ]),
    );
  }
}
