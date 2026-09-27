import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:material_3_expressive/material_3_expressive.dart';

import '../domain/models.dart';
import '../domain/assessment.dart';
import 'components.dart';

class ReportDetailsPage extends StatefulWidget {
  const ReportDetailsPage({
    super.key,
    required this.report,
    required this.path,
  });
  final ScanReport report;
  final NetworkPath path;
  @override
  State<ReportDetailsPage> createState() => _ReportDetailsPageState();
}

class _ReportDetailsPageState extends State<ReportDetailsPage> {
  late NetworkPath path = widget.path;
  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final assessment = Assessment.forPath(report, path);
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(title: const Text('测试详情')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 840),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SectionTitle(
                    Uri.parse(report.config.target).host,
                    subtitle: report.config.target,
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: report.config.paths
                        .map(
                          (p) => M3EChip(
                            type: M3EChipType.filter,
                            label: p.label,
                            selected: path == p,
                            onPressed: () => setState(() => path = p),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                  Panel(
                    padding: 8,
                    child: ExpansionTile(
                      title: const Text('判定依据'),
                      shape: const Border(),
                      collapsedShape: const Border(),
                      childrenPadding: const EdgeInsets.all(16),
                      children: [
                        for (final line in assessment.evidence)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(line),
                            ),
                          ),
                        if (report.failure != null)
                          SelectableText(report.failure!),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  _EvidenceList(report: report, path: path),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EvidenceList extends StatefulWidget {
  const _EvidenceList({required this.report, required this.path});
  final ScanReport report;
  final NetworkPath path;
  @override
  State<_EvidenceList> createState() => _EvidenceListState();
}

class _EvidenceListState extends State<_EvidenceList> {
  bool failuresOnly = false, showControl = false, showSkipped = false;
  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final targetHost = Uri.parse(report.config.target).host;
    final rows = report.results
        .where(
          (r) =>
              r.path == widget.path &&
              (showControl || r.host == targetHost) &&
              (!failuresOnly ||
                  r.state == ProbeState.failed ||
                  r.state == ProbeState.httpError) &&
              (showSkipped || r.state != ProbeState.skipped),
        )
        .toList();
    final groups = <String, List<ProbeResult>>{};
    for (final row in rows) {
      groups.putIfAbsent(row.groupKey, () => []).add(row);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle('连接记录', subtitle: '${rows.length} 条记录'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            M3EChip(
              type: M3EChipType.filter,
              label: '仅看异常',
              selected: failuresOnly,
              onPressed: () => setState(() => failuresOnly = !failuresOnly),
            ),
            M3EChip(
              type: M3EChipType.filter,
              label: '包含测试基线',
              selected: showControl,
              onPressed: () => setState(() => showControl = !showControl),
            ),
            M3EChip(
              type: M3EChipType.filter,
              label: '显示跳过项',
              selected: showSkipped,
              onPressed: () => setState(() => showSkipped = !showSkipped),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (groups.isEmpty)
          const EmptyPanel(
            icon: Icons.filter_alt_off_outlined,
            title: '暂无匹配记录',
            body: '请调整筛选条件。',
          ),
        ...groups.values.map((g) {
          final row = g.first;
          final successes = g.where((r) => r.usable).length;
          final state = g.every((r) => r.usable)
              ? ProbeState.success
              : g.any((r) => r.state == ProbeState.failed)
              ? ProbeState.failed
              : row.state;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Panel(
              padding: 4,
              radius: 20,
              child: ExpansionTile(
                shape: const Border(),
                collapsedShape: const Border(),
                leading: _StatusMark(state),
                title: Text(
                  row.strategy.label,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                subtitle: Text(
                  '${row.host}\n${row.address ?? '域名连接'} · $successes/${g.length} 可用',
                ),
                children: g
                    .map(
                      (r) => ListTile(
                        leading: _StatusMark(r.state, size: 18),
                        title: Text(
                          '第 ${r.attempt} 轮 · ${_stateLabel(r.state)} · ${r.elapsedMs} ms',
                        ),
                        subtitle: Text(
                          r.statusCode != null
                              ? 'HTTP ${r.statusCode} · ECH ${r.echAccepted ? '已接受' : '未接受或未启用'}'
                              : r.errorKind ?? r.detail,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => _showProbeDetail(context, r),
                      ),
                    )
                    .toList(),
              ),
            ),
          );
        }),
        const SizedBox(height: 24),
        Panel(
          padding: 8,
          child: ExpansionTile(
            title: const Text('DNS 与 ECH 配置'),
            shape: const Border(),
            collapsedShape: const Border(),
            children: [
              ...report.discoveries
                  .where(
                    (d) =>
                        d.path == widget.path &&
                        (showControl || d.host == targetHost),
                  )
                  .map(
                    (d) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Panel(
                        padding: 8,
                        child: ExpansionTile(
                          shape: const Border(),
                          collapsedShape: const Border(),
                          leading: Icon(
                            d.configList == null
                                ? Icons.dns_outlined
                                : Icons.enhanced_encryption_outlined,
                          ),
                          title: Text(d.host),
                          subtitle: Text(
                            d.configList == null
                                ? '未获得 ECH 配置'
                                : 'ECH 来源：${d.configSource}${d.borrowed ? ' · 备用配置' : ''}',
                          ),
                          childrenPadding: const EdgeInsets.all(16),
                          children: [
                            _line('系统 IP', d.systemIps.join('\n')),
                            _line('DoH IP', d.dohIps.join('\n')),
                            _line('地址解析服务', d.endpoint ?? '无'),
                            if (report.config.forceCloudflare)
                              _line(
                                'Cloudflare IP',
                                report.config.cloudflareIps.join('\n'),
                              ),
                            ...d.notes.map(
                              (note) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: SelectableText(
                                    note,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                ),
                              ),
                            ),
                            if (d.configList != null)
                              _line('ECHConfigList', d.configList!),
                          ],
                        ),
                      ),
                    ),
                  ),
              const SizedBox(height: 24),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Panel(
          padding: 8,
          child: ExpansionTile(
            title: const Text('运行日志'),
            subtitle: Text('${report.events.length} 条事件'),
            shape: const Border(),
            collapsedShape: const Border(),
            childrenPadding: const EdgeInsets.all(16),
            children: [
              SelectableText(
                report.events.join('\n'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _line(String name, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          SelectableText(value.isEmpty ? '无' : value),
        ],
      ),
    ),
  );
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, {this.icon});
  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              text,
              style: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusMark extends StatelessWidget {
  const _StatusMark(this.state, {this.size = 22});
  final ProbeState state;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (icon, color) = switch (state) {
      ProbeState.success => (Icons.check_circle_rounded, colors.primary),
      ProbeState.httpError => (Icons.warning_amber_rounded, colors.tertiary),
      ProbeState.failed => (Icons.cancel_rounded, colors.error),
      ProbeState.skipped => (
        Icons.remove_circle_outline_rounded,
        colors.outline,
      ),
      ProbeState.cancelled => (Icons.stop_circle_outlined, colors.outline),
    };
    return Icon(
      icon,
      color: color,
      size: size,
      semanticLabel: _stateLabel(state),
    );
  }
}

String _stateLabel(ProbeState state) => switch (state) {
  ProbeState.success => '可用',
  ProbeState.httpError => '网站响应异常',
  ProbeState.failed => '失败',
  ProbeState.skipped => '跳过',
  ProbeState.cancelled => '已停止',
};

void _showProbeDetail(BuildContext context, ProbeResult r) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 720),
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionTitle(
                r.strategy.label,
                subtitle: '${r.host} · ${r.path.label} · 第 ${r.attempt} 轮',
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _Tag(_stateLabel(r.state)),
                  _Tag('${r.elapsedMs} ms'),
                  if (r.echAccepted)
                    const _Tag('ECH 已接受', icon: Icons.verified_user_outlined),
                ],
              ),
              const SizedBox(height: 20),
              SelectableText(
                '连接地址：${r.address ?? '域名解析'}\n'
                'HTTP：${r.statusCode ?? '无响应'}\nECH 重试：${r.echRetries}\n'
                '配置来源：${r.configSource ?? '未使用'}\n原生错误码：${r.nativeCode ?? '无'}\n'
                'Server：${r.server ?? '无'}\nLocation：${r.location ?? '无'}\n\n${r.detail}',
              ),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                icon: const Icon(Icons.copy_rounded),
                label: const Text('复制详情'),
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(
                      text:
                          '${r.host}\n${r.strategy.label}\n${r.address ?? ''}\n${r.detail}',
                    ),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('已复制')));
                  }
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
