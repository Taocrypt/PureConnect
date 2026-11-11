// First-launch disclaimer, after FlClash's DisclaimerView
// (https://github.com/chen08209/FlClash, GPL-3.0): numbered terms, and on
// first launch a consent bar whose 同意 stays off until the confirmation
// phrase is in the field (typed, or filled with one tap).
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../core/desktop_shell.dart';
import '../../l10n/strings.dart';
import '../kit/app_glyphs.dart';
import '../kit/common.dart';
import '../kit/dashboard_kit.dart';

/// Number of numbered terms (keys `disclaimer_t{i}_title` / `_body`).
const disclaimerTermCount = 9;

/// Whether [input] is the confirmation phrase (surrounding spaces ignored,
/// nothing else).
bool disclaimerPhraseMatches(String input, String phrase) => input.trim() == phrase;

/// Shows the disclaimer for consent. True once agreed; any other way out
/// (退出) declines.
Future<bool> requestDisclaimerConsent(BuildContext context) async =>
    await pushPage<bool>(context, (_) => const DisclaimerPage(requireConsent: true)) ?? false;

/// Leaves the app after the disclaimer was declined: Android finishes the
/// activity, desktop quits cleanly (tray, core).
Future<void> exitAfterDecline() async {
  if (Platform.isAndroid) {
    await SystemNavigator.pop();
  } else {
    await DesktopShell.instance.quit();
  }
}

class DisclaimerPage extends StatefulWidget {
  const DisclaimerPage({super.key, this.requireConsent = false});

  final bool requireConsent;

  @override
  State<DisclaimerPage> createState() => _DisclaimerPageState();
}

class _DisclaimerPageState extends State<DisclaimerPage> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final terms = <Widget>[
      _Intro(text: context.tr('disclaimer_intro')),
      for (var i = 1; i <= disclaimerTermCount; i++)
        _Term(index: i, title: context.tr('disclaimer_t${i}_title'), content: context.tr('disclaimer_t${i}_body')),
      if (widget.requireConsent) _Confirmation(controller: _controller),
    ];
    final page = AppPage(
      canPop: !widget.requireConsent,
      title: context.tr('disclaimer'),
      body: widget.requireConsent
          ? Column(children: [
              Expanded(child: PageList(children: terms)),
              _ConsentBar(controller: _controller),
            ])
          : PageList(children: terms),
    );
    if (!widget.requireConsent) return page;
    // Back / swipe does not get past it: 退出 or 同意 only.
    return PopScope(canPop: false, child: page);
  }
}

class _Intro extends StatelessWidget {
  const _Intro({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = context.colorScheme;
    return DashboardBlock(
      padding: const EdgeInsets.all(20),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, spacing: 16, children: [
        GlyphIcon(AppGlyphs.gavel, size: 28, color: cs.primary),
        Expanded(
          child: Text(text,
              style: AppTextStyle.subheadline.of(context).copyWith(color: cs.onSurfaceVariant, height: 1.6)),
        ),
      ]),
    );
  }
}

class _Term extends StatelessWidget {
  const _Term({required this.index, required this.title, required this.content});
  final int index;
  final String title;
  final String content;

  @override
  Widget build(BuildContext context) {
    final cs = context.colorScheme;
    final style = AppTextStyle.subheadline.of(context).copyWith(color: cs.onSurfaceVariant, height: 1.6);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 28, 4, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(spacing: 12, children: [
          DecoratedBox(
            decoration: ShapeDecoration(color: cs.surfaceContainerHighest, shape: AppShape.full),
            child: SizedBox.square(
              dimension: 28,
              child: Center(
                child: Text('$index',
                    style: AppTextStyle.caption1.of(context, emphasized: true).copyWith(color: cs.onSurfaceVariant)),
              ),
            ),
          ),
          Expanded(child: Text(title, style: AppTextStyle.headline.of(context))),
        ]),
        const SizedBox(height: 12),
        for (final (i, para) in content.split('\n\n').indexed)
          Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : 10), child: Text(para, style: style)),
      ]),
    );
  }
}

/// The phrase to restate, the field, and 一键填入.
class _Confirmation extends StatelessWidget {
  const _Confirmation({required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final cs = context.colorScheme;
    final phrase = context.tr('disclaimer_phrase');
    return Padding(
      padding: const EdgeInsets.only(top: 32),
      child: DashboardBlock(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 12, children: [
          Text(context.tr('disclaimer_restate_tip'),
              style: AppTextStyle.subheadline.of(context).copyWith(color: cs.onSurfaceVariant)),
          DecoratedBox(
            decoration: ShapeDecoration(color: cs.surfaceContainerHighest, shape: AppShape.lg),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: SelectableText(phrase, style: AppTextStyle.body.of(context, emphasized: true)),
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final typed = value.text.trim();
              final mismatch = typed.isNotEmpty && !phrase.startsWith(typed) && !disclaimerPhraseMatches(typed, phrase);
              return Row(crossAxisAlignment: CrossAxisAlignment.start, spacing: 8, children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    decoration: InputDecoration(
                      hintText: context.tr('disclaimer_restate_hint'),
                      errorText: mismatch ? context.tr('disclaimer_restate_mismatch') : null,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => controller.value = TextEditingValue(
                    text: phrase,
                    selection: TextSelection.collapsed(offset: phrase.length),
                  ),
                  child: Text(context.tr('disclaimer_fill')),
                ),
              ]);
            },
          ),
        ]),
      ),
    );
  }
}

class _ConsentBar extends StatelessWidget {
  const _ConsentBar({required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final phrase = context.tr('disclaimer_phrase');
    final mobile = isMobileLayout(context);
    return DecoratedBox(
      decoration: BoxDecoration(color: SurfaceLevel.page.colorOf(context.colorScheme)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: mobile ? 16 : 24, vertical: 12),
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final ok = disclaimerPhraseMatches(value.text, phrase);
              final exit = OutlinedButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(context.tr('disclaimer_exit')),
              );
              final agree = FilledButton(
                onPressed: ok ? () => Navigator.of(context).pop(true) : null,
                child: Text(context.tr('disclaimer_agree')),
              );
              return Row(spacing: 12, children: mobile
                  ? [Expanded(child: exit), Expanded(child: agree)]
                  : [const Spacer(), exit, agree]);
            },
          ),
        ),
      ),
    );
  }
}
