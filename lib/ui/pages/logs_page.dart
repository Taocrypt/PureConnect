import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../core/protocol.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../kit/app_glyphs.dart';
import '../kit/common.dart';
import '../kit/dashboard_kit.dart';

class LogsPage extends ConsumerStatefulWidget {
  const LogsPage({super.key, this.pushed = false});

  /// Opened from Tools on a phone, rather than as a sidebar tab.
  final bool pushed;

  @override
  ConsumerState<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends ConsumerState<LogsPage> {
  String _level = 'all';
  String _q = '';

  String _ts(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final logs = ref.watch(logsProvider);
    final q = _q.toLowerCase();
    final List<LogEntry> shown = logs
        .where((e) => _level == 'all' || e.level == _level)
        .where((e) => q.isEmpty || e.message.toLowerCase().contains(q))
        .toList();
    final colorScheme = context.colorScheme;
    final mobile = isMobileLayout(context);
    final side = mobile ? 16.0 : 24.0;
    final bottom = (mobile && !widget.pushed ? NavigationDock.heightOf(context) + 24 : 24) +
        MediaQuery.paddingOf(context).bottom;

    return AppPage(
      title: context.tr('logs'),
      canPop: widget.pushed,
      actions: [
        HeaderAction(
          glyph: AppGlyphs.copy,
          tooltip: context.tr('copy'),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: shown.map((e) => '${_ts(e.time)} [${e.level}] ${e.message}').join('\n')));
            showToast(context, context.tr('copied'), level: BannerLevel.success);
          },
        ),
        HeaderAction(
          glyph: AppGlyphs.export,
          tooltip: context.tr('export_logs'),
          onPressed: () async {
            final text = logs.map((e) => '${_ts(e.time)} [${e.level}] ${e.message}').join('\n');
            try {
              final r = await FilePicker.saveFile(
                fileName: 'pureconnect-${DateTime.now().millisecondsSinceEpoch ~/ 1000}.log',
                bytes: Uint8List.fromList(utf8.encode('$text\n')),
                mimeType: 'text/plain',
              );
              if (r != null && context.mounted) showToast(context, context.tr('saved'), level: BannerLevel.success);
            } catch (e) {
              if (context.mounted) showToast(context, '$e', level: BannerLevel.error);
            }
          },
        ),
        HeaderAction(glyph: AppGlyphs.clearAll, tooltip: context.tr('clear'), onPressed: ref.read(logsProvider.notifier).clear),
      ],
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: EdgeInsets.fromLTRB(side, 0, side, 10),
          child: SegmentedControl<String>(
            segments: [
              ('all', context.tr('level_all')),
              ('info', 'Info'),
              ('warning', 'Warning'),
              ('error', 'Error'),
            ],
            value: _level,
            onChanged: (v) => setState(() => _level = v),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(side, 0, side, 12),
          child: SearchField(onChanged: (v) => setState(() => _q = v)),
        ),
        Expanded(
          child: shown.isEmpty
              ? EmptyHint(glyph: AppGlyphs.logs, text: context.tr('empty'))
              : Padding(
                  padding: EdgeInsets.fromLTRB(side, 0, side, bottom),
                  child: DashboardCard(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                    child: ListView.builder(
                      reverse: true,
                      itemCount: shown.length,
                      itemBuilder: (context, i) {
                        final e = shown[shown.length - 1 - i];
                        final dot = switch (e.level) {
                          'error' => colorScheme.error,
                          'warning' => colorScheme.warning,
                          _ => colorScheme.primary,
                        };
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, spacing: 10, children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 5),
                              child: DecoratedBox(
                                decoration: ShapeDecoration(color: dot, shape: AppShape.circle),
                                child: const SizedBox.square(dimension: 6),
                              ),
                            ),
                            Text(_ts(e.time), style: DashboardText.label(context)),
                            Expanded(
                              child: SelectableText(e.message,
                                  style: AppTextStyle.footnote.of(context).copyWith(fontFamily: 'monospace')),
                            ),
                          ]),
                        );
                      },
                    ),
                  ),
                ),
        ),
      ]),
    );
  }
}
