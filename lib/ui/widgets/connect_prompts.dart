import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../l10n/strings.dart';
import '../../models/profile.dart';
import '../kit/app_glyphs.dart';
import '../kit/dashboard_kit.dart';

/// What [askLogin] returns: the typed values and whether to keep them.
class LoginAnswer {
  const LoginAnswer({this.username = '', this.password = '', this.phone = '', this.remember = false});
  final String username, password, phone;
  final bool remember;
}

/// Which details [profile] still lacks to sign in, if any: 'password'
/// (user name / password) or 'phone' (aTrust SMS login).
String? missingLogin(Profile profile) {
  if (profile.protocol == VpnProtocol.easyconnect) {
    if (profile.certFile.isNotEmpty || profile.twfId.isNotEmpty) return null;
    return profile.username.isEmpty || profile.password.isEmpty ? 'password' : null;
  }
  switch (profile.authType) {
    case AtrustAuthType.password:
      return profile.username.isEmpty || profile.password.isEmpty ? 'password' : null;
    case AtrustAuthType.sms:
      return profile.phone.isEmpty ? 'phone' : null;
    default:
      return null;
  }
}

/// Asks for the sign-in details a profile does not store, with a "remember"
/// switch that saves them into the profile.
Future<LoginAnswer?> askLogin(BuildContext context, Profile profile, String kind) {
  return showFloatingDialog<LoginAnswer>(context: context, child: _LoginDialog(profile, kind));
}

class _LoginDialog extends StatefulWidget {
  const _LoginDialog(this.profile, this.kind);
  final Profile profile;
  final String kind;

  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
  late final _user = TextEditingController(text: widget.profile.username);
  late final _pass = TextEditingController(text: widget.profile.password);
  late final _phone = TextEditingController(text: widget.profile.phone);
  bool _show = false;
  bool _remember = false;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _phone.dispose();
    super.dispose();
  }

  void _submit() {
    if (widget.kind == 'phone' ? _phone.text.trim().isEmpty : (_user.text.trim().isEmpty || _pass.text.isEmpty)) return;
    Navigator.pop(
      context,
      LoginAnswer(username: _user.text.trim(), password: _pass.text, phone: _phone.text.trim(), remember: _remember),
    );
  }

  Widget _label(String text) => Text(text, style: DashboardText.label(context));

  @override
  Widget build(BuildContext context) {
    final phone = widget.kind == 'phone';
    final name = widget.profile.name.isEmpty ? widget.profile.effectiveServer : widget.profile.name;
    return AlertDialog(
      title: context.tr(phone ? 'login_phone_title' : 'login_title'),
      hasFields: true,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('cancel'))),
        TextButton(onPressed: _submit, child: Text(context.tr('connect'))),
      ],
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 8, children: [
        Text(name, style: DashboardText.label(context)),
        if (phone) ...[
          _label(context.tr('phone')),
          TextField(
            controller: _phone,
            autofocus: true,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(hintText: '13800000000'),
            onSubmitted: (_) => _submit(),
          ),
        ] else ...[
          _label(context.tr('username')),
          TextField(controller: _user, autofocus: _user.text.isEmpty, autocorrect: false),
          _label(context.tr('password')),
          TextField(
            controller: _pass,
            autofocus: _user.text.isNotEmpty,
            obscureText: !_show,
            autocorrect: false,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              suffixIcon: IconButton(
                tooltip: context.tr(_show ? 'hide_password' : 'show_password'),
                onPressed: () => setState(() => _show = !_show),
                icon: GlyphIcon(_show ? AppGlyphs.eyeOff : AppGlyphs.eye, size: 20),
              ),
            ),
          ),
        ],
        Row(children: [
          Expanded(child: Text(context.tr('login_remember'), style: AppTextStyle.subheadline.of(context))),
          DashboardSwitch(value: _remember, onChanged: (v) => setState(() => _remember = v)),
        ]),
      ]),
    );
  }
}

/// Another app's system proxy is on: replace it? Returns null on cancel,
/// else whether "don't ask again" was ticked.
Future<bool?> confirmProxyOverride(BuildContext context, String current) {
  var dontAsk = false;
  return showFloatingDialog<bool>(
    context: context,
    child: StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: ctx.tr('proxy_override_title'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.tr('cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, dontAsk), child: Text(ctx.tr('proxy_override_go'))),
        ],
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 10, children: [
          Text(ctx.tr('proxy_override_body', {'proxy': current})),
          Row(children: [
            Expanded(child: Text(ctx.tr('dont_show_again'), style: AppTextStyle.subheadline.of(ctx))),
            DashboardSwitch(value: dontAsk, onChanged: (v) => setState(() => dontAsk = v)),
          ]),
        ]),
      ),
    ),
  );
}
