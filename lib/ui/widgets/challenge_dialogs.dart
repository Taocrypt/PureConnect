import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../core/protocol.dart';
import '../../l10n/strings.dart';
import '../kit/app_glyphs.dart';
import '../kit/common.dart';
import '../kit/dashboard_kit.dart';

/// Shows the right dialog for an authentication challenge coming from the
/// core (SMS / TOTP / radius code, text captcha, click captcha, CAS/OAuth2).
Future<ChallengeAnswer?> showChallengeDialog(BuildContext context, Challenge c) {
  return showFloatingDialog<ChallengeAnswer>(
    context: context,
    dismissible: false,
    child: switch (c.kind) {
      ChallengeKind.code => _CodeDialog(c),
      ChallengeKind.textCaptcha => _TextCaptchaDialog(c),
      ChallengeKind.clickCaptcha => _ClickCaptchaDialog(c),
      ChallengeKind.externalLogin => _ExternalLoginDialog(c),
    },
  );
}

List<Widget> _actions(BuildContext context, VoidCallback? onSubmit) => [
      TextButton(
        onPressed: () => Navigator.pop(context, const ChallengeAnswer.cancelled()),
        child: Text(context.tr('cancel')),
      ),
      TextButton(onPressed: onSubmit, child: Text(context.tr('submit'))),
    ];

class _CodeDialog extends StatefulWidget {
  const _CodeDialog(this.c);
  final Challenge c;
  @override
  State<_CodeDialog> createState() => _CodeDialogState();
}

class _CodeDialogState extends State<_CodeDialog> {
  final _ctl = TextEditingController();
  bool _skip = false;

  @override
  Widget build(BuildContext context) {
    final title = switch (widget.c.codeKind) {
      'sms' => context.tr('challenge_sms'),
      'totp' => context.tr('challenge_totp'),
      _ => context.tr('challenge_code'),
    };
    void submit() => Navigator.pop(context, ChallengeAnswer(code: _ctl.text.trim(), skipSecondaryAuth: _skip));
    return AlertDialog(
      title: title,
      hasFields: true,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 10, children: [
        if (widget.c.message.isNotEmpty) Text(widget.c.message, style: DashboardText.label(context)),
        TextField(controller: _ctl, autofocus: true, keyboardType: TextInputType.number, onSubmitted: (_) => submit()),
        if (widget.c.canSkip)
          Row(children: [
            Expanded(child: Text(context.tr('skip_secondary'), style: AppTextStyle.subheadline.of(context))),
            DashboardSwitch(value: _skip, onChanged: (v) => setState(() => _skip = v)),
          ]),
      ]),
      actions: _actions(context, submit),
    );
  }
}

class _TextCaptchaDialog extends StatefulWidget {
  const _TextCaptchaDialog(this.c);
  final Challenge c;
  @override
  State<_TextCaptchaDialog> createState() => _TextCaptchaDialogState();
}

class _TextCaptchaDialogState extends State<_TextCaptchaDialog> {
  final _ctl = TextEditingController();

  @override
  Widget build(BuildContext context) {
    void submit() => Navigator.pop(context, ChallengeAnswer(code: _ctl.text.trim()));
    return AlertDialog(
      title: context.tr('challenge_captcha'),
      hasFields: true,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 10, children: [
        if (widget.c.imagePath.isNotEmpty)
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(File(widget.c.imagePath), height: 80, fit: BoxFit.contain, gaplessPlayback: true),
          ),
        TextField(controller: _ctl, autofocus: true, onSubmitted: (_) => submit()),
      ]),
      actions: _actions(context, submit),
    );
  }
}

/// Click captcha: tap characters in order; points are reported in the
/// image's natural pixel coordinates, like upstream's browser helper.
class _ClickCaptchaDialog extends StatefulWidget {
  const _ClickCaptchaDialog(this.c);
  final Challenge c;
  @override
  State<_ClickCaptchaDialog> createState() => _ClickCaptchaDialogState();
}

class _ClickCaptchaDialogState extends State<_ClickCaptchaDialog> {
  final _points = <(int, int)>[];
  ui.Image? _img;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await File(widget.c.imagePath).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    if (mounted) setState(() => _img = frame.image);
  }

  @override
  Widget build(BuildContext context) {
    final img = _img;
    final colorScheme = context.colorScheme;
    return AlertDialog(
      title: context.tr('challenge_click'),
      hasFields: true,
      child: img == null
          ? const SizedBox(height: 120, child: Center(child: ActivityIndicator()))
          : Column(mainAxisSize: MainAxisSize.min, spacing: 8, children: [
              LayoutBuilder(builder: (context, c) {
                final scale = (c.maxWidth / img.width).clamp(0.2, 1.5);
                final w = img.width * scale, h = img.height * scale;
                return GestureDetector(
                  onTapDown: (d) => setState(() =>
                      _points.add(((d.localPosition.dx / scale).round(), (d.localPosition.dy / scale).round()))),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      width: w,
                      height: h,
                      child: Stack(children: [
                        Positioned.fill(child: RawImage(image: img, fit: BoxFit.fill)),
                        for (final (i, p) in _points.indexed)
                          Positioned(
                            left: p.$1 * scale - 14,
                            top: p.$2 * scale - 14,
                            child: Container(
                              width: 28,
                              height: 28,
                              alignment: Alignment.center,
                              decoration: ShapeDecoration(color: colorScheme.primary, shape: AppShape.circle),
                              child: Text('${i + 1}',
                                  style: AppTextStyle.footnote.of(context, emphasized: true).copyWith(color: colorScheme.onPrimary)),
                            ),
                          ),
                      ]),
                    ),
                  ),
                );
              }),
              if (widget.c.message.isNotEmpty) Text(widget.c.message, style: DashboardText.label(context)),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton.icon(
                  onPressed: _points.isEmpty ? null : () => setState(_points.removeLast),
                  icon: const GlyphIcon(AppGlyphs.undo),
                  label: Text(context.tr('undo')),
                ),
                TextButton.icon(
                  onPressed: _points.isEmpty ? null : () => setState(_points.clear),
                  icon: const GlyphIcon(AppGlyphs.clearAll),
                  label: Text(context.tr('clear')),
                ),
              ]),
            ]),
      actions: _actions(
        context,
        _points.isEmpty || img == null
            ? null
            : () => Navigator.pop(context, ChallengeAnswer(points: List.of(_points), width: img.width, height: img.height)),
      ),
    );
  }
}

class _ExternalLoginDialog extends StatefulWidget {
  const _ExternalLoginDialog(this.c);
  final Challenge c;
  @override
  State<_ExternalLoginDialog> createState() => _ExternalLoginDialogState();
}

class _ExternalLoginDialogState extends State<_ExternalLoginDialog> {
  final _ctl = TextEditingController();

  @override
  Widget build(BuildContext context) {
    void submit() => Navigator.pop(context, ChallengeAnswer(callbackUrl: _ctl.text.trim()));
    return AlertDialog(
      title: '${context.tr('challenge_external')} · ${widget.c.codeKind.toUpperCase()}',
      hasFields: true,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 10, children: [
        Text(context.tr('challenge_external_hint'), style: DashboardText.label(context)),
        if (widget.c.loginUrl.isNotEmpty)
          FilledButton.icon(
            onPressed: () => openInBrowser(context, widget.c.loginUrl),
            icon: const GlyphIcon(AppGlyphs.openExternal),
            label: Text(context.tr('open_browser')),
          ),
        TextField(
          controller: _ctl,
          decoration: InputDecoration(hintText: context.tr('callback_url')),
          onSubmitted: (_) => submit(),
        ),
      ]),
      actions: _actions(context, submit),
    );
  }
}
