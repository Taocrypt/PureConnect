import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../core/config_builder.dart' show clientDataFile;
import '../../l10n/strings.dart';
import '../../models/profile.dart';
import '../../state/providers.dart';
import '../kit/app_glyphs.dart';
import '../kit/common.dart';
import '../kit/dashboard_kit.dart';
import '../tour/guide_tour.dart';

class ProfileEditPage extends ConsumerStatefulWidget {
  const ProfileEditPage({super.key, required this.profile, this.isNew = false, this.guided = false});
  final Profile profile;
  final bool isNew;

  /// Opened by the setup tour: its controls are tour targets, saving selects
  /// the profile, and the sign-in methods are read from the server.
  final bool guided;

  @override
  ConsumerState<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends ConsumerState<ProfileEditPage> {
  late final Profile p = widget.profile;
  final _c = <String, TextEditingController>{};
  bool _busy = false;
  bool _showSecrets = false;

  /// Sign-in methods the server offered, for the auth type picker.
  List<GuideAuthOption> _serverAuth = const [];
  String? _serverAuthFor;
  bool _loadingAuth = false;

  static const _editorSteps = [GuideStep.protocol, GuideStep.server, GuideStep.auth, GuideStep.credentials, GuideStep.save];
  GuideTour get _tour => GuideTour.instance;
  GuideStep? _tourStep;

  @override
  void initState() {
    super.initState();
    if (widget.guided) {
      _tour.skipIf = (s) => s == GuideStep.auth && p.protocol != VpnProtocol.atrust;
      _tour.bind(GuideStep.server, () {
        final err = _checkServer();
        if (err != null) {
          showToast(context, err, level: BannerLevel.warning);
        } else {
          _tour.advance(from: GuideStep.server);
        }
      });
      _tour.bind(GuideStep.credentials, () {
        final err = _checkCredentials();
        if (err != null) {
          showToast(context, err, level: BannerLevel.warning);
        } else {
          _tour.advance(from: GuideStep.credentials);
        }
      });
      _tour.bind(GuideStep.save, _save);
      _tour.addListener(_onTour);
    }
  }

  void _onTour() {
    final s = _tour.step;
    if (s == _tourStep || !mounted) return;
    _tourStep = s;
    if (s == GuideStep.auth) _loadServerAuth();
    if (s == GuideStep.credentials) FocusScope.of(context).unfocus();
  }

  /// Only ZJU servers get the "Disable ZJU defaults" switch; for any other
  /// host the core is always told to skip the ZJU rules (config_builder).
  bool get _serverIsZju {
    final h = (_c['server']?.text ?? widget.profile.serverAddress).trim().toLowerCase();
    return h == 'zju.edu.cn' || h.endsWith('.zju.edu.cn');
  }

  TextEditingController _ctl(String key, String initial) => _c.putIfAbsent(key, () => TextEditingController(text: initial));

  @override
  void dispose() {
    if (widget.guided) {
      _tour.removeListener(_onTour);
      _tour.unbind(_editorSteps);
      // Leaving the editor mid-tour ends the tour (after this frame).
      Future.microtask(_tour.editorClosed);
    }
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Tour: the server step needs a usable host and port.
  String? _checkServer() {
    _collect();
    final host = p.serverAddress.trim();
    if (host.isEmpty || host.contains(' ') || host.contains('/')) return context.tr('guide_bad_server');
    if (p.serverPort < 1 || p.serverPort > 65535) return '${context.tr('server_port')}: 1-65535';
    return null;
  }

  /// Tour: the credentials the chosen sign-in method needs now.
  String? _checkCredentials() {
    _collect();
    final at = p.protocol == VpnProtocol.atrust;
    final needsPassword = at ? p.authType == AtrustAuthType.password : p.certFile.isEmpty;
    if (needsPassword && (p.username.isEmpty || p.password.isEmpty)) return context.tr('guide_need_password');
    if (at && p.authType == AtrustAuthType.sms && p.phone.isEmpty) return context.tr('guide_need_phone');
    return null;
  }

  /// Reads the server's sign-in methods quietly for the auth type picker.
  Future<void> _loadServerAuth() async {
    _collect();
    if (p.protocol != VpnProtocol.atrust || p.serverAddress.isEmpty) return;
    final key = '${p.serverAddress}:${p.serverPort}';
    if (_serverAuthFor == key || _loadingAuth) return;
    setState(() => _loadingAuth = true);
    _tour.setNote(context.tr('tour_auth_reading'));
    final r = await ref.read(coreProvider.notifier).fetchAuthInfo(p);
    if (!mounted) return;
    setState(() {
      _loadingAuth = false;
      if (r.ok) {
        _serverAuth = GuideAuthOption.parse(r.authInfo);
        _serverAuthFor = key;
      }
    });
    if (_tour.step == GuideStep.auth) {
      _tour.setNote(r.ok
          ? (_serverAuth.isEmpty ? context.tr('tour_auth_none') : context.tr('tour_auth_found', {'n': '${_serverAuth.length}'}))
          : context.tr('tour_auth_failed'));
    }
  }

  String _v(String key) => _c[key]?.text.trim() ?? '';

  /// Copies the text fields back into the profile.
  void _collect() {
    if (_c.containsKey('name')) p.name = _v('name');
    if (_c.containsKey('server')) p.serverAddress = _v('server');
    if (_c.containsKey('port')) p.serverPort = int.tryParse(_v('port')) ?? 443;
    if (_c.containsKey('user')) p.username = _v('user');
    if (_c.containsKey('pass')) p.password = _c['pass']!.text;
    if (_c.containsKey('totp')) p.totpSecret = _v('totp');
    if (_c.containsKey('phone')) p.phone = _v('phone');
    if (_c.containsKey('cas')) p.casTicket = _v('cas');
    if (_c.containsKey('oauth')) p.oauth2Code = _v('oauth');
    if (_c.containsKey('certpass')) p.certPassword = _c['certpass']!.text;
    if (_c.containsKey('twf')) p.twfId = _v('twf');
    if (_c.containsKey('domain')) p.loginDomain = _v('domain');
    if (_c.containsKey('mac')) {
      p.macAddresses = _v('mac').split(RegExp(r'[,\s]+')).where((e) => e.isNotEmpty).toList();
    }
  }

  void _save() {
    _collect();
    // A profile made in the tour is named after its server.
    if (widget.guided && p.name.isEmpty) p.name = p.serverAddress.trim();
    if (p.name.isEmpty) {
      showToast(context, '${context.tr('name')}?', level: BannerLevel.warning);
      return;
    }
    p.serverAddress = p.serverAddress.trim();
    if (p.serverAddress.isEmpty) {
      showToast(context, '${context.tr('server_address')}?', level: BannerLevel.warning);
      return;
    }
    if (p.serverPort < 1 || p.serverPort > 65535) {
      showToast(context, '${context.tr('server_port')}: 1-65535', level: BannerLevel.warning);
      return;
    }
    ref.read(profilesProvider.notifier).upsert(p);
    if (widget.guided) {
      ref.read(settingsProvider.notifier).update((s) {
        s.selectedProfileId = p.id;
        s.setupGuideShown = true;
      });
      showToast(context, context.tr('guide_done'), level: BannerLevel.success);
      _tour.advance(from: GuideStep.save);
    } else if (widget.isNew) {
      ref.read(settingsProvider.notifier).update((s) => s.selectedProfileId ??= p.id);
    }
    Navigator.of(context).pop();
  }

  Future<void> _authInfo() async {
    _collect();
    setState(() => _busy = true);
    final r = await ref.read(coreProvider.notifier).fetchAuthInfo(p);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r.ok) {
        _serverAuth = GuideAuthOption.parse(r.authInfo);
        _serverAuthFor = '${p.serverAddress}:${p.serverPort}';
      }
    });
    final text = r.ok ? const JsonEncoder.withIndent('  ').convert(r.authInfo) : (r.error ?? 'error');
    await showFloatingDialog(
      context: context,
      child: Builder(
        builder: (ctx) => AlertDialog(
          title: ctx.tr('fetch_auth_info'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.tr('ok')))],
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: SingleChildScrollView(
              child: SelectableText(text, style: AppTextStyle.caption1.of(ctx).copyWith(fontFamily: 'monospace')),
            ),
          ),
        ),
      ),
    );
  }

  /// Deletes the saved aTrust client data (session, device id, cookies).
  Future<void> _clearLoginCache() async {
    final ok = await confirm(context,
        title: context.tr('clear_login_cache'), message: context.tr('clear_login_cache_confirm'), destructive: true);
    if (!ok || !mounted) return;
    try {
      final f = clientDataFile(ref.read(dataDirProvider), p);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    if (mounted) showToast(context, context.tr('clear_login_cache_done'), level: BannerLevel.success);
  }

  Future<void> _trust(bool trust) async {
    setState(() => _busy = true);
    final r = await ref.read(coreProvider.notifier).setTrusted(p, trust);
    if (!mounted) return;
    setState(() => _busy = false);
    showToast(context, r.ok ? context.tr('ok') : (r.error ?? 'error'),
        level: r.ok ? BannerLevel.success : BannerLevel.error);
  }

  Widget _field(String key, String label, String initial,
      {bool secret = false, String? hint, TextInputType? type}) {
    return GuideTarget(
      id: 'field:$key',
      enabled: widget.guided,
      child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 8, children: [
        Text(label, style: DashboardText.label(context)),
        TextField(
          controller: _ctl(key, initial),
          obscureText: secret && !_showSecrets,
          keyboardType: type,
          autocorrect: false,
          // The ZJU-only switch depends on the server address.
          onChanged: key == 'server' ? (_) => setState(() {}) : null,
          decoration: InputDecoration(
            hintText: hint,
            suffixIcon: secret
                ? IconButton(
                    tooltip: _showSecrets
                        ? UiLocalizations.of(context).hidePassword
                        : UiLocalizations.of(context).showPassword,
                    onPressed: () => setState(() => _showSecrets = !_showSecrets),
                    icon: GlyphIcon(_showSecrets ? AppGlyphs.eyeOff : AppGlyphs.eye, size: 20),
                  )
                : null,
          ),
        ),
      ]),
      ),
    );
  }

  Widget _switch(String title, bool value, void Function(bool) set, {String? subtitle}) => SwitchTile(
        title: title,
        subtitle: subtitle,
        value: value,
        onChanged: (v) => setState(() => set(v)),
      );

  /// Auth type picker: the server's own sign-in methods first (when read),
  /// then the manual choices. A server method also sets the login domain.
  Future<void> _pickAuthType() async {
    final server = [
      for (final o in _serverAuth)
        if (AtrustAuthType.values.any((t) => t.value == o.authType)) o,
    ];
    final current = server.where((o) => o.authType == p.authType.value && o.loginDomain == p.loginDomain).firstOrNull ??
        p.authType;
    final v = await pickOne<Object>(
      context,
      title: context.tr('auth_type'),
      current: current,
      options: [
        for (final o in server)
          (o, [if (o.name.isNotEmpty) o.name, o.authType, if (o.loginDomain.isNotEmpty) o.loginDomain].join(' · ')),
        (AtrustAuthType.auto, context.tr('auto')),
        (AtrustAuthType.password, '${context.tr('password')} (auth/psw)'),
        (AtrustAuthType.sms, '${context.tr('challenge_sms')} (auth/smsCheckCode)'),
        (AtrustAuthType.cas, 'CAS (auth/cas)'),
        (AtrustAuthType.oauth2, 'OAuth2 (auth/httpsOauth2)'),
      ],
    );
    if (v == null || !mounted) return;
    _collect();
    setState(() {
      if (v is GuideAuthOption) {
        p.authType = AtrustAuthType.fromValue(v.authType);
        if (v.loginDomain.isNotEmpty) {
          p.loginDomain = v.loginDomain;
          _c['domain']?.text = v.loginDomain;
        }
      } else if (v is AtrustAuthType) {
        p.authType = v;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final at = p.protocol == VpnProtocol.atrust;
    final showPassword = !at || p.authType == AtrustAuthType.password || p.authType == AtrustAuthType.auto;
    final authLabel = switch (p.authType) {
      AtrustAuthType.auto => context.tr('auto'),
      AtrustAuthType.password => context.tr('password'),
      AtrustAuthType.sms => context.tr('challenge_sms'),
      AtrustAuthType.cas => 'CAS',
      AtrustAuthType.oauth2 => 'OAuth2',
    };
    if (widget.guided) {
      final browser = at && (p.authType == AtrustAuthType.cas || p.authType == AtrustAuthType.oauth2);
      final sms = at && p.authType == AtrustAuthType.sms;
      _tour.credentialsVariant = sms ? 'sms' : (browser ? 'browser' : null);
    }
    return AppPage(
      canPop: true,
      title: widget.isNew ? context.tr('add_profile') : context.tr('edit_profile'),
      actions: [
        if (_busy) const Padding(padding: EdgeInsets.all(12), child: ActivityIndicator(size: 20)),
        GuideTarget(
          id: 'save',
          enabled: widget.guided,
          child: HeaderAction(glyph: AppGlyphs.check, tooltip: context.tr('save'), filled: true, onPressed: _save),
        ),
      ],
      body: PageList(children: [
        SettingsGroup(title: context.tr('general'), children: [
          _field('name', context.tr('name'), p.name),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: GuideTarget(
              id: 'protocol',
              enabled: widget.guided,
              child: SegmentedControl<VpnProtocol>(
                segments: const [(VpnProtocol.easyconnect, 'EasyConnect'), (VpnProtocol.atrust, 'aTrust')],
                value: p.protocol,
                onChanged: (v) => setState(() {
                  _collect();
                  p.protocol = v;
                }),
              ),
            ),
          ),
          _field('server', context.tr('server_address'), p.serverAddress,
              hint: at ? 'vpn.xxx.edu.cn' : 'xvpn.xxx.edu.cn', type: TextInputType.url),
          _field('port', context.tr('server_port'), '${p.serverPort}', type: TextInputType.number),
        ]),
        SettingsGroup(title: context.tr('account'), children: [
          if (at)
            GuideTarget(
              id: 'auth',
              enabled: widget.guided,
              child: SettingsTile(
                title: context.tr('auth_type'),
                trailing: _loadingAuth
                    ? const ActivityIndicator(size: 16)
                    : Text(authLabel, style: DashboardText.label(context)),
                chevron: !_loadingAuth,
                onTap: _pickAuthType,
              ),
            ),
          if (showPassword) ...[
            _field('user', context.tr('username'), p.username),
            _field('pass', context.tr('password'), p.password, secret: true),
          ],
          if (at && (p.authType == AtrustAuthType.sms || p.authType == AtrustAuthType.auto))
            _field('phone', context.tr('phone'), p.phone, type: TextInputType.phone),
          if (at && p.authType == AtrustAuthType.cas)
            _field('cas', context.tr('cas_ticket'), p.casTicket, hint: context.tr('browser_login_hint')),
          if (at && p.authType == AtrustAuthType.oauth2)
            _field('oauth', context.tr('oauth2_code'), p.oauth2Code, hint: context.tr('browser_login_hint')),
          _field('totp', context.tr('totp_secret'), p.totpSecret, secret: true),
        ]),
        SettingsGroup(title: context.tr('advanced'), children: [
          if (!at) ...[
            SettingsTile(
              title: context.tr('cert_file'),
              subtitle: p.certFile.isEmpty ? '—' : p.certFile,
              trailing: p.certFile.isEmpty
                  ? null
                  : IconButton(
                      tooltip: context.tr('clear'),
                      onPressed: () => setState(() => p.certFile = ''),
                      icon: const GlyphIcon(AppGlyphs.close, size: 18),
                    ),
              chevron: p.certFile.isEmpty,
              onTap: () async {
                final r = await FilePicker.pickFiles(type: FileType.any);
                final path = r.isEmpty ? null : r.first.path;
                if (path != null) setState(() => p.certFile = path);
              },
            ),
            if (p.certFile.isNotEmpty) _field('certpass', context.tr('cert_password'), p.certPassword, secret: true),
            _field('twf', context.tr('twf_id'), p.twfId),
            if (_serverIsZju)
              _switch(context.tr('disable_zju_config'), p.disableZjuConfig, (v) => p.disableZjuConfig = v),
            _switch(context.tr('skip_domain_resource'), p.skipDomainResource, (v) => p.skipDomainResource = v),
            _switch(context.tr('disable_multi_line'), p.disableMultiLine, (v) => p.disableMultiLine = v),
          ],
          if (at) ...[
            _field('domain', context.tr('login_domain'), p.loginDomain),
            _switch(context.tr('save_client_data'), p.saveClientData, (v) => p.saveClientData = v),
            _field('mac', 'MAC', p.macAddresses.join(', '), hint: 'aa:bb:cc:dd:ee:ff'),
          ],
          _switch(context.tr('disable_server_config'), p.disableServerConfig, (v) => p.disableServerConfig = v),
        ]),
        if (at)
          SettingsGroup(title: 'aTrust', children: [
            SettingsTile(glyph: AppGlyphs.search, title: context.tr('fetch_auth_info'), chevron: true, onTap: _busy ? null : _authInfo),
            SettingsTile(
              glyph: AppGlyphs.verified,
              title: context.tr('trust_device'),
              subtitle: p.saveClientData ? null : context.tr('save_client_data'),
              onTap: _busy || !p.saveClientData ? null : () => _trust(true),
            ),
            SettingsTile(
              glyph: AppGlyphs.block,
              title: context.tr('untrust_device'),
              onTap: _busy || !p.saveClientData ? null : () => _trust(false),
            ),
            SettingsTile(
              glyph: AppGlyphs.clearAll,
              title: context.tr('clear_login_cache'),
              destructive: true,
              onTap: _busy ? null : _clearLoginCache,
            ),
          ]),
      ]),
    );
  }
}
