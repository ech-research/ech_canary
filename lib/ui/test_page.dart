import 'package:material_ui/material_ui.dart';
import 'package:material_3_expressive/material_3_expressive.dart';

import '../app_controller.dart';
import '../domain/assessment.dart';
import '../domain/models.dart';
import 'components.dart';
import 'evidence.dart';

class TestPage extends StatefulWidget {
  const TestPage({super.key, required this.controller});
  final AppController controller;
  @override
  State<TestPage> createState() => _TestPageState();
}

class _TestPageState extends State<TestPage> {
  AppController get c => widget.controller;
  late final target = TextEditingController(text: c.config.target);
  late final proxy = TextEditingController(text: c.config.proxy);
  late Set<NetworkPath> paths = c.config.paths.toSet();
  late ScanConfig lastConfig = c.config;
  NetworkPath selectedPath = NetworkPath.direct;
  String? error;
  bool saving = false;

  @override
  void didUpdateWidget(covariant TestPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Advanced settings must not discard an unfinished domain.
    if (lastConfig.target != c.config.target) target.text = c.config.target;
    if (lastConfig.proxy != c.config.proxy) proxy.text = c.config.proxy;
    if (lastConfig.paths != c.config.paths) paths = c.config.paths.toSet();
    lastConfig = c.config;
  }

  @override
  void dispose() {
    target.dispose();
    proxy.dispose();
    super.dispose();
  }

  Future<void> start([ScanConfig? repeat]) async {
    if (saving || c.running) return;
    final next =
        repeat ??
        c.config.copyWith(
          target: ScanConfig.httpsInput(target.text),
          proxy: proxy.text.trim(),
          paths: paths.toList()..sort((a, b) => a.index.compareTo(b.index)),
        );
    final invalid = next.validate();
    if (invalid != null) {
      setState(() => error = invalid);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await c.saveConfig(next);
      if (!mounted) return;
      c.start();
    } catch (_) {
      if (mounted) setState(() => error = '设置未能保存，请重试。');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (c.message != null || error != null) ...[
        Panel(
          color: Theme.of(context).colorScheme.errorContainer,
          child: Text(
            error ?? c.message!,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
      if (c.running)
        _progress(context)
      else if (c.report != null)
        _result(context, c.report!)
      else
        _composer(context),
    ],
  );

  Widget _composer(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Panel(
          radius: 32,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const Key('target-input'),
                controller: target,
                enabled: !saving,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.go,
                autocorrect: false,
                enableSuggestions: false,
                onSubmitted: (_) => start(),
                decoration: const InputDecoration(
                  labelText: '受限域名',
                  prefixIcon: Icon(Icons.language_rounded),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(20)),
                  ),
                ),
              ),
              const SizedBox(height: 28),
              Text('连接方式', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: NetworkPath.values
                    .map(
                      (p) => M3EChip(
                        key: ValueKey('path-${p.name}'),
                        type: M3EChipType.filter,
                        label: p.label,
                        selected: paths.contains(p),
                        leading: Icon(
                          p == NetworkPath.direct
                              ? Icons.wifi_rounded
                              : Icons.route_outlined,
                          size: 18,
                        ),
                        onPressed: saving
                            ? null
                            : () => setState(() {
                                if (paths.contains(p)) {
                                  if (paths.length > 1) paths.remove(p);
                                } else {
                                  paths.add(p);
                                }
                              }),
                      ),
                    )
                    .toList(),
              ),
              if (paths.contains(NetworkPath.proxy)) ...[
                const SizedBox(height: 20),
                TextField(
                  key: const Key('proxy-input'),
                  controller: proxy,
                  enabled: !saving,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    hintText: 'http://host:port',
                    helperText: '支持 HTTP CONNECT',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(20)),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: M3EButton.icon(
                  key: const Key('start-scan'),
                  onPressed: saving ? null : () => start(),
                  size: M3EButtonSize.md,
                  icon: const Icon(Icons.arrow_forward_rounded),
                  label: Text(saving ? '保存设置…' : '开始测试'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _progress(BuildContext context) {
    final config = c.report?.config ?? c.config;
    final stopping = c.stopping;
    final colors = Theme.of(context).colorScheme;
    return Panel(
      key: const Key('scan-progress'),
      radius: 32,
      color: colors.primaryContainer,
      child: DefaultTextStyle.merge(
        style: TextStyle(color: colors.onPrimaryContainer),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              stopping ? '正在停止…' : '正在测试',
              style: Theme.of(context).textTheme.headlineMedium
                  ?.copyWith(color: colors.onPrimaryContainer),
            ),
            const SizedBox(height: 16),
            Text(
              Uri.parse(config.target).host,
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(color: colors.onPrimaryContainer),
            ),
            const SizedBox(height: 8),
            Text(config.paths.map((p) => p.label).join(' · ')),
            const SizedBox(height: 32),
            M3EProgressIndicator.linearWavy(
              value: c.total == 0 ? null : c.completed / c.total,
              semanticsLabel: '测试进度',
            ),
            const SizedBox(height: 16),
            Text(
              c.total == 0
                  ? '查找域名地址与 ECH 配置'
                  : '已完成 ${c.completed} / ${c.total} 项',
            ),
            const SizedBox(height: 28),
            M3EButton.icon(
              onPressed: stopping ? null : c.cancel,
              icon: const Icon(Icons.stop_rounded),
              label: const Text('停止测试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _result(BuildContext context, ScanReport report) {
    final colors = Theme.of(context).colorScheme;
    final activePath = report.config.paths.contains(selectedPath)
        ? selectedPath
        : report.config.paths.first;
    final assessment = Assessment.forPath(report, activePath);
    final good = assessment.tone == FindingTone.good;
    final background = good
        ? colors.primaryContainer
        : colors.secondaryContainer;
    final foreground = good
        ? colors.onPrimaryContainer
        : colors.onSecondaryContainer;
    final recommended = assessment.recommended;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          Uri.parse(report.config.target).host,
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(
          dateLabel(report.startedAt),
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        if (report.config.paths.length > 1) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: report.config.paths
                .map(
                  (p) => M3EChip(
                    type: M3EChipType.filter,
                    label: p.label,
                    selected: activePath == p,
                    onPressed: () => setState(() => selectedPath = p),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 16),
        ],
        Panel(
          color: background,
          radius: 32,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                good
                    ? Icons.check_circle_outline_rounded
                    : Icons.info_outline_rounded,
                size: 36,
                color: foreground,
              ),
              const SizedBox(height: 18),
              Text(
                assessment.title,
                style: Theme.of(context).textTheme.headlineMedium
                    ?.copyWith(color: foreground, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Text(
                assessment.summary,
                style: Theme.of(context).textTheme.bodyLarge
                    ?.copyWith(color: foreground, height: 1.5),
              ),
              const SizedBox(height: 24),
              if (recommended != null) ...[
                Text(
                  '可用方式',
                  style: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(color: foreground),
                ),
                const SizedBox(height: 8),
                Text(
                  recommended.strategy.label,
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(color: foreground),
                ),
                if (recommended.address != null) ...[
                  const SizedBox(height: 8),
                  SelectableText(
                    recommended.address!,
                    style: TextStyle(color: foreground),
                  ),
                ],
                const SizedBox(height: 20),
              ],
              Text(
                activePath == NetworkPath.proxy
                    ? '前置代理 · ${Uri.parse(report.config.proxy).authority}'
                    : '连接方式 · 直连',
                style: TextStyle(color: foreground),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Panel(
          padding: 4,
          child: ListTile(
            leading: const Icon(Icons.fact_check_outlined),
            title: const Text('测试详情'),
            subtitle: const Text('连接结果与判定依据'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    ReportDetailsPage(report: report, path: activePath),
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            M3EButton.icon(
              onPressed: saving ? null : () => start(report.config),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('再次测试'),
              size: M3EButtonSize.md,
            ),
            M3EButton.icon(
              onPressed: saving
                  ? null
                  : () {
                      setState(() => error = null);
                      c.newTest();
                    },
              icon: const Icon(Icons.edit_outlined),
              label: const Text('更换域名'),
              style: M3EButtonStyle.outlined,
              size: M3EButtonSize.md,
            ),
          ],
        ),
      ],
    );
  }
}
