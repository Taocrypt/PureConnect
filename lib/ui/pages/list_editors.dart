import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../../l10n/strings.dart';
import '../../models/settings.dart';
import '../../state/providers.dart';
import '../widgets/app_list.dart';
import '../kit/app_glyphs.dart';
import '../kit/common.dart';
import '../kit/dashboard_kit.dart';

class TextTile extends StatelessWidget {
  const TextTile({super.key, required this.title, required this.value, required this.onChanged, this.hint, this.obscure = false});

  final String title, value;
  final String? hint;
  final bool obscure;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => SettingsTile(
        title: title,
        subtitle: value.isEmpty ? (hint ?? '—') : (obscure ? '••••••' : value),
        chevron: true,
        onTap: () async {
          final v = await editTextDialog(context, title: title, initial: value, hint: hint, obscure: obscure);
          if (v != null) onChanged(v.trim());
        },
      );
}

class IntTile extends StatelessWidget {
  const IntTile({super.key, required this.title, required this.value, required this.onChanged, this.min = 0, this.max = 1 << 31});

  final String title;
  final int value, min, max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => SettingsTile(
        title: title,
        trailing: Text('$value', style: AppTextStyle.body.of(context, emphasized: true).toTabular),
        chevron: true,
        onTap: () async {
          final v = await editTextDialog(context, title: title, initial: '$value', type: TextInputType.number);
          final n = int.tryParse(v ?? '');
          if (n != null && n >= min && n <= max) onChanged(n);
        },
      );
}

/// Dialog with labelled text fields; returns their values or null.
Future<List<String>?> _fieldsDialog(
  BuildContext context, {
  required String title,
  required List<(String label, String hint, String initial)> fields,
  Widget Function(StateSetter set)? header,
}) {
  final ctls = [for (final f in fields) TextEditingController(text: f.$3)];
  return showFloatingDialog<List<String>>(
    context: context,
    child: StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: title,
        hasFields: true,
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.tr('cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, [for (final c in ctls) c.text.trim()]), child: Text(ctx.tr('save'))),
        ],
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 10, children: [
          if (header != null) header(set),
          for (final (i, f) in fields.indexed) ...[
            Text(f.$1, style: DashboardText.label(ctx)),
            TextField(controller: ctls[i], autocorrect: false, decoration: InputDecoration(hintText: f.$2)),
          ],
        ]),
      ),
    ),
  );
}

class _ListScaffold extends StatelessWidget {
  const _ListScaffold({required this.children, required this.onAdd, this.footer});

  final List<Widget> children;
  final VoidCallback onAdd;
  final String? footer;

  @override
  Widget build(BuildContext context) => PageList(children: [
        if (children.isNotEmpty) SettingsGroup(footer: footer, children: children),
        if (children.isEmpty) ...[
          const SizedBox(height: 40),
          EmptyHint(glyph: AppGlyphs.listAdd, text: context.tr('empty')),
        ],
        const SizedBox(height: 8),
        Center(
          child: FilledButton.icon(
            onPressed: onAdd,
            icon: const GlyphIcon(AppGlyphs.add),
            label: Text(context.tr('add')),
          ),
        ),
      ]);
}

Widget _deleteButton(BuildContext context, VoidCallback onPressed) => IconButton(
      tooltip: context.tr('delete'),
      onPressed: onPressed,
      icon: GlyphIcon(AppGlyphs.delete, size: 20, color: context.colorScheme.error),
    );

class PortForwardEditor extends ConsumerWidget {
  const PortForwardEditor({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, [int? index]) async {
    final list = ref.read(settingsProvider).portForwards;
    final f = index == null ? PortForward(bind: '127.0.0.1:') : PortForward.fromJson(list[index].toJson());
    var network = f.network;
    final r = await _fieldsDialog(
      context,
      title: context.tr('port_forwarding'),
      header: (set) => SegmentedControl<String>(
        segments: const [('tcp', 'TCP'), ('udp', 'UDP')],
        value: network,
        onChanged: (v) => set(() => network = v),
      ),
      fields: [
        (context.tr('bind_address'), '127.0.0.1:8080', f.bind),
        (context.tr('remote_address'), '10.10.98.98:80', f.remote),
      ],
    );
    if (r == null || r[0].isEmpty || r[1].isEmpty) return;
    final item = PortForward(network: network, bind: r[0], remote: r[1]);
    ref.read(settingsProvider.notifier).update((s) {
      index == null ? s.portForwards.add(item) : s.portForwards[index] = item;
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(settingsProvider.select((s) => s.portForwards));
    return _ListScaffold(
      onAdd: () => _edit(context, ref),
      children: [
        for (final (i, f) in list.indexed)
          SettingsTile(
            title: '${f.bind}  →  ${f.remote}',
            subtitle: f.network.toUpperCase(),
            onTap: () => _edit(context, ref, i),
            trailing: _deleteButton(context, () => ref.read(settingsProvider.notifier).update((s) => s.portForwards.removeAt(i))),
          ),
      ],
    );
  }
}

class CustomDnsEditor extends ConsumerWidget {
  const CustomDnsEditor({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, [int? index]) async {
    final list = ref.read(settingsProvider).customDns;
    final r = await _fieldsDialog(
      context,
      title: context.tr('custom_dns'),
      fields: [
        (context.tr('host_name'), 'www.cc98.org', index == null ? '' : list[index].host),
        ('IP', '10.10.98.98', index == null ? '' : list[index].ip),
      ],
    );
    if (r == null || r[0].isEmpty || r[1].isEmpty) return;
    final item = CustomDns(host: r[0], ip: r[1]);
    ref.read(settingsProvider.notifier).update((s) {
      index == null ? s.customDns.add(item) : s.customDns[index] = item;
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(settingsProvider.select((s) => s.customDns));
    return _ListScaffold(
      onAdd: () => _edit(context, ref),
      children: [
        for (final (i, d) in list.indexed)
          SettingsTile(
            title: d.host,
            subtitle: d.ip,
            onTap: () => _edit(context, ref, i),
            trailing: _deleteButton(context, () => ref.read(settingsProvider.notifier).update((s) => s.customDns.removeAt(i))),
          ),
      ],
    );
  }
}

class ProxyDomainEditor extends ConsumerWidget {
  const ProxyDomainEditor({super.key});

  static final _domain = RegExp(r'^[a-zA-Z\d-]+(\.[a-zA-Z\d-]+)*\.[a-zA-Z]{2,}$');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(settingsProvider.select((s) => s.customProxyDomains));
    return _ListScaffold(
      footer: context.tr('custom_proxy_domain_hint'),
      onAdd: () async {
        final v = await editTextDialog(context, title: context.tr('domain'), initial: '', hint: 'cc98.org');
        if (v == null) return;
        if (!_domain.hasMatch(v.trim())) {
          if (context.mounted) showToast(context, '${context.tr('domain')}: $v ✗', level: BannerLevel.warning);
          return;
        }
        ref.read(settingsProvider.notifier).update((s) => s.customProxyDomains.add(v.trim()));
      },
      children: [
        for (final (i, d) in list.indexed)
          SettingsTile(
            title: d,
            trailing: _deleteButton(context, () => ref.read(settingsProvider.notifier).update((s) => s.customProxyDomains.removeAt(i))),
          ),
      ],
    );
  }
}

/// Android packages kept outside the VPN (the front proxy app).
class BypassAppsEditor extends ConsumerWidget {
  const BypassAppsEditor({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(settingsProvider.select((s) => s.bypassApps));
    return AppListView(
      selected: list.toSet(),
      footer: context.tr('bypass_apps_hint'),
      onToggle: (pkg, v) => ref.read(settingsProvider.notifier).update((s) {
        s.bypassApps.remove(pkg);
        if (v) s.bypassApps.add(pkg);
      }),
    );
  }
}
