import 'package:material_ui/material_ui.dart';
import 'package:material_3_expressive/material_3_expressive.dart';

import '../domain/models.dart';
import 'components.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.config,
    required this.running,
    required this.onSave,
  });
  final ScanConfig config;
  final bool running;
  final Future<void> Function(ScanConfig) onSave;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final control = TextEditingController(text: widget.config.control);
  late final doh = TextEditingController(
    text: widget.config.dohEndpoints.join('\n'),
  );
  late final manual = TextEditingController(
    text: widget.config.manualIps.join('\n'),
  );
  late final cf = TextEditingController(
    text: widget.config.cloudflareIps.join('\n'),
  );
  late final source = TextEditingController(text: widget.config.configDomain);
  late bool shared = widget.config.trySharedConfig,
      forceCf = widget.config.forceCloudflare;
  late int attempts = widget.config.attempts,
      timeout = widget.config.timeoutSeconds,
      maxIps = widget.config.maxAddresses;
  bool saving = false;
  String? error;
  bool get locked => widget.running || saving;

  @override
  void dispose() {
    for (final c in [control, doh, manual, cf, source]) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> lines(String value) => value
      .split(RegExp(r'[\s,，]+'))
      .where((s) => s.isNotEmpty)
      .toSet()
      .toList();

  Future<void> save() async {
    final config = widget.config.copyWith(
      control: ScanConfig.httpsInput(control.text),
      dohEndpoints: lines(doh.text),
      manualIps: lines(manual.text),
      cloudflareIps: lines(cf.text),
      configDomain: source.text.trim(),
      trySharedConfig: shared,
      forceCloudflare: forceCf,
      attempts: attempts,
      timeoutSeconds: timeout,
      maxAddresses: maxIps,
    );
    final invalid = config.validate(requireTarget: false);
    if (invalid != null) {
      setState(() => error = invalid);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.onSave(config);
      messenger.showSnackBar(const SnackBar(content: Text('设置已保存')));
    } catch (_) {
      if (mounted) setState(() => error = '保存失败，请重试。');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Widget field(
    String label,
    TextEditingController controller, {
    String? helper,
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: TextField(
      controller: controller,
      enabled: !locked,
      maxLines: lines,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 3,
        filled: true,
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
          borderSide: BorderSide.none,
        ),
      ),
    ),
  );

  Widget group(
    String title,
    String subtitle,
    IconData icon,
    List<Widget> children,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Panel(
      padding: 4,
      radius: 24,
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: children,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (widget.running)
        const Padding(
          padding: EdgeInsets.only(bottom: 16),
          child: Text('结束测试后可修改设置。'),
        ),
      group('测试次数与超时', '每项 $attempts 次 · 超时 $timeout 秒', Icons.timer_outlined, [
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('每项测试次数'),
          trailing: Text('$attempts 次'),
        ),
        Slider(
          value: attempts.toDouble(),
          min: 1,
          max: 3,
          divisions: 2,
          label: '$attempts 次',
          onChanged: locked
              ? null
              : (v) => setState(() => attempts = v.round()),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('单次请求超时'),
          trailing: Text('$timeout 秒'),
        ),
        Slider(
          value: timeout.toDouble(),
          min: 3,
          max: 30,
          divisions: 27,
          label: '$timeout 秒',
          onChanged: locked ? null : (v) => setState(() => timeout = v.round()),
        ),
      ]),
      const SizedBox(height: 16),
      const SectionTitle('高级设置'),
      group(
        'IP Overwrite',
        forceCf
            ? 'Cloudflare IP Overwrite 测试已启用'
            : 'Cloudflare IP Overwrite 测试已禁用',
        Icons.alt_route_rounded,
        [
          SwitchListTile.adaptive(
            key: const Key('force-cloudflare'),
            contentPadding: EdgeInsets.zero,
            value: forceCf,
            title: const Text('尝试 Cloudflare IP'),
            subtitle: const Text('为域名额外测试一组连接地址'),
            onChanged: locked ? null : (v) => setState(() => forceCf = v),
          ),
          if (forceCf)
            field('Cloudflare 候选 IP', cf, lines: 2, helper: '最多 4 个，每行一个'),
          field(
            '指定目标 IP（可选）',
            manual,
            lines: 2,
            helper: '最多 4 个 IPv4 或 IPv6 地址',
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('每种解析方式最多测试'),
            trailing: Text('$maxIps 个 IP'),
          ),
          Slider(
            value: maxIps.toDouble(),
            min: 1,
            max: 4,
            divisions: 3,
            label: '$maxIps 个',
            onChanged: locked
                ? null
                : (v) => setState(() => maxIps = v.round()),
          ),
        ],
      ),
      group('DNS', 'Security DNS Resolver', Icons.dns_outlined, [
        field('DoH 服务', doh, lines: 3, helper: '最多 3 个 DNS JSON 地址，按顺序尝试'),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          value: shared,
          title: const Text('使用备用 ECH 配置'),
          subtitle: const Text('目标未提供配置时，尝试其他域名的配置'),
          onChanged: locked ? null : (v) => setState(() => shared = v),
        ),
        if (shared) field('备用配置域名', source),
      ]),
      group('测试基线', '未受限的ECH基准', Icons.compare_arrows_rounded, [
        field('测试基线地址', control, helper: '使用与测试目标不同、支持 ECH 的站点'),
      ]),
      if (error != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      const SizedBox(height: 12),
      M3EButton.icon(
        onPressed: locked ? null : save,
        icon: const Icon(Icons.check_rounded),
        label: Text(saving ? '保存中…' : '保存设置'),
        size: M3EButtonSize.md,
      ),
    ],
  );
}
