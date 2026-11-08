import 'dart:convert';

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

class ProfileEditPage extends ConsumerStatefulWidget {
  const ProfileEditPage({super.key, required this.profile, this.isNew = false});
  final Profile profile;
  final bool isNew;

  @override
  ConsumerState<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends ConsumerState<ProfileEditPage> {
  late final Profile p = widget.profile;
  final _c = <String, TextEditingController>{};
  bool _busy = false;
  bool _showSecrets = false;

  /// Only ZJU servers get the "Disable ZJU defaults" switch; for any other
  /// host the core is always told to skip the ZJU rules (config_builder).
  bool get _serverIsZju {
    final h = (_c['server']?.text ?? widget.profile.serverAddress).trim().toLowerCase();
    return h == 'zju.edu.cn' || h.endsWith('.zju.edu.cn');
  }

  TextEditingController _ctl(String key, String initial) => _c.putIfAbsent(key, () => TextEditingController(text: initial));

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
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
    if (p.name.isEmpty) {
      showToast(context, '${context.tr('name')}?', level: BannerLevel.warning);
      return;
    }
    if (p.serverPort < 1 || p.serverPort > 65535) {
      showToast(context, '${context.tr('server_port')}: 1-65535', level: BannerLevel.warning);
      return;
    }
    ref.read(profilesProvider.notifier).upsert(p);
    if (widget.isNew) {
      ref.read(settingsProvider.notifier).update((s) => s.selectedProfileId ??= p.id);
    }
    Navigator.of(context).pop();
  }

  Future<void> _authInfo() async {
    _collect();
    setState(() => _busy = true);
    final r = await ref.read(coreProvider.notifier).fetchAuthInfo(p);
    if (!mounted) return;
    setState(() => _busy = false);
    final text = r.ok ? const JsonEncoder.withIndent('  ').convert(r.authInfo) : (r.error ?? 'error');
    await showFloatingDialog(
      context: context,
      child: Builder(
        builder: (ctx) => AlertDialog(
          title: ctx.tr('fetch_auth_info'),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: SingleChildScrollView(
              child: SelectableText(text, style: AppTextStyle.caption1.of(ctx).copyWith(fontFamily: 'monospace')),
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.tr('ok')))],
        ),
      ),
    );
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
    return Padding(
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
    );
  }

  Widget _switch(String title, bool value, void Function(bool) set, {String? subtitle}) => SwitchTile(
        title: title,
        subtitle: subtitle,
        value: value,
        onChanged: (v) => setState(() => set(v)),
      );

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
    return AppPage(
      canPop: true,
      title: widget.isNew ? context.tr('add_profile') : context.tr('edit_profile'),
      actions: [
        if (_busy) const Padding(padding: EdgeInsets.all(12), child: ActivityIndicator(size: 20)),
        HeaderAction(glyph: AppGlyphs.check, tooltip: context.tr('save'), filled: true, onPressed: _save),
      ],
      body: PageList(children: [
        SettingsGroup(title: context.tr('general'), children: [
          _field('name', context.tr('name'), p.name),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: SegmentedControl<VpnProtocol>(
              segments: const [(VpnProtocol.easyconnect, 'EasyConnect'), (VpnProtocol.atrust, 'aTrust')],
              value: p.protocol,
              onChanged: (v) => setState(() {
                _collect();
                p.protocol = v;
                if (v == VpnProtocol.atrust && (p.serverAddress.isEmpty || p.serverAddress == 'rvpn.zju.edu.cn')) {
                  p.serverAddress = 'vpn.zju.edu.cn';
                  _c['server']?.text = p.serverAddress;
                }
                if (v == VpnProtocol.easyconnect && (p.serverAddress.isEmpty || p.serverAddress == 'vpn.zju.edu.cn')) {
                  p.serverAddress = 'rvpn.zju.edu.cn';
                  _c['server']?.text = p.serverAddress;
                }
              }),
            ),
          ),
          _field('server', context.tr('server_address'), p.serverAddress,
              hint: at ? 'vpn.zju.edu.cn' : 'rvpn.zju.edu.cn', type: TextInputType.url),
          _field('port', context.tr('server_port'), '${p.serverPort}', type: TextInputType.number),
        ]),
        SettingsGroup(title: context.tr('account'), children: [
          if (at)
            SettingsTile(
              title: context.tr('auth_type'),
              trailing: Text(authLabel, style: DashboardText.label(context)),
              chevron: true,
              onTap: () async {
                final v = await pickOne<AtrustAuthType>(
                  context,
                  title: context.tr('auth_type'),
                  current: p.authType,
                  options: [
                    (AtrustAuthType.auto, context.tr('auto')),
                    (AtrustAuthType.password, '${context.tr('password')} (auth/psw)'),
                    (AtrustAuthType.sms, '${context.tr('challenge_sms')} (auth/smsCheckCode)'),
                    (AtrustAuthType.cas, 'CAS (auth/cas)'),
                    (AtrustAuthType.oauth2, 'OAuth2 (auth/httpsOauth2)'),
                  ],
                );
                if (v != null) {
                  _collect();
                  setState(() => p.authType = v);
                }
              },
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
          ]),
      ]),
    );
  }
}
