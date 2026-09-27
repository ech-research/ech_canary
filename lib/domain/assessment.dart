import 'models.dart';

enum FindingTone { neutral, good, caution }

class Assessment {
  const Assessment({
    required this.title,
    required this.summary,
    required this.tone,
    required this.ech,
    required this.ip,
    required this.doh,
    required this.evidence,
    this.recommended,
  });
  final String title, summary, ech, ip, doh;
  final FindingTone tone;
  final List<String> evidence;
  final ProbeResult? recommended;

  static Assessment forPath(ScanReport report, NetworkPath path) {
    final host = Uri.parse(report.config.target).host;
    final control = Uri.parse(report.config.control).host;
    final target = report.results
        .where((r) => r.path == path && r.host == host)
        .toList();
    final baseline = target
        .where((r) => r.strategy == Strategy.baseline)
        .toList();
    final controlBaseline = report.results
        .where(
          (r) =>
              r.path == path &&
              r.host == control &&
              r.strategy == Strategy.baseline,
        )
        .toList();
    final groups = <String, List<ProbeResult>>{};
    for (final r in target) {
      groups.putIfAbsent(r.groupKey, () => []).add(r);
    }
    bool stable(List<ProbeResult> rows) =>
        rows.length == report.config.attempts && rows.every((r) => r.usable);
    final working = groups.values.where(stable).map((g) => g.first).toList()
      ..sort((a, b) => _cost(a.strategy).compareTo(_cost(b.strategy)));
    final accepted = target.where((r) => r.echAccepted).toList();
    final observed = target.where((r) => r.reachable).toList();
    final complete = report.complete;
    final minimum = complete && working.isNotEmpty ? working.first : null;
    final evidence = <String>[
      '本路径普通 TLS：${baseline.where((r) => r.reachable).length}/${baseline.length} 次可达。',
      '测试基线普通 TLS：${controlBaseline.where((r) => r.reachable).length}/${controlBaseline.length} 次可达。',
      'ECH 以握手结果为准；HTTP 错误不等于 TLS 失败。',
    ];
    var title = '尚无结论', summary = '等待测试完成。';
    var tone = FindingTone.neutral;
    if (!complete) {
      title = report.cancelled
          ? '测试已停止'
          : report.failure != null
          ? '测试未完成'
          : '正在测试';
      summary = '已保留现有结果，可重新测试。';
    } else if (baseline.any((r) => r.reachable)) {
      final stableBaseline = stable(baseline);
      title = stableBaseline ? '可以正常访问' : '连接不稳定或网站响应异常';
      summary = stableBaseline ? '此连接方式下，无需 ECH 即可访问。' : '已连接到网站，但部分请求失败或返回错误。';
      tone = stableBaseline ? FindingTone.good : FindingTone.caution;
    } else if (minimum != null) {
      title = '找到可用方式';
      summary = '普通连接失败，以下方式通过了全部 ${report.config.attempts} 轮测试。';
      tone = FindingTone.good;
    } else if (observed.isNotEmpty) {
      title = '尚无稳定的连接方式';
      summary = '部分请求得到响应，但没有方式通过全部测试。';
      tone = FindingTone.caution;
    } else if (controlBaseline.any((r) => r.reachable)) {
      title = '暂时无法访问';
      summary = '测试基线可连接，目标域名均未成功，可能受限或存在服务故障。';
      tone = FindingTone.caution;
    } else {
      title = '请检查连接';
      summary = path == NetworkPath.proxy
          ? '目标和测试基线均未连通，请检查前置代理。'
          : '目标和测试基线均未连通，请检查网络。';
      tone = FindingTone.caution;
    }
    var ech = accepted.isEmpty ? '未验证' : '已接受';
    if (complete &&
        target.any((r) => r.strategy.ech && r.state == ProbeState.failed) &&
        accepted.isEmpty) {
      ech = '未成功';
    }
    var ip = minimum == null
        ? '未确定'
        : minimum.strategy.overridesIp
        ? '覆写方案可用'
        : '无需覆写';
    var doh = '用于 ECH 配置发现';
    final echHost = working.where((r) => r.strategy == Strategy.echHost);
    final echIp = working.where(
      (r) => r.strategy.ech && r.strategy.overridesIp,
    );
    if (complete && echHost.isEmpty && echIp.isNotEmpty) {
      final hostTests = target
          .where((r) => r.strategy == Strategy.echHost)
          .toList();
      if (hostTests.length == report.config.attempts &&
          hostTests.every((r) => r.state == ProbeState.failed)) {
        ip = 'ECH 需配合覆写';
        evidence.add('ECH 域名连接失败，IP 连接成功；域名 CONNECT 仍暴露目标名。');
      }
    }
    if (minimum?.strategy == Strategy.dohIp ||
        minimum?.strategy == Strategy.echDohIp) {
      doh = 'DoH 地址可用';
    } else if (minimum?.strategy == Strategy.cloudflareIp ||
        minimum?.strategy == Strategy.echCloudflareIp) {
      doh = '仅使用 ECH 配置';
      evidence.add('Cloudflare 覆写独立于 DoH 地址；结论仅适用于已测 IP。');
    } else if (complete &&
        working.any(
          (r) =>
              r.strategy == Strategy.systemIp ||
              r.strategy == Strategy.echSystemIp,
        )) {
      doh = '系统 IP 亦可用';
    }
    for (final good in working.where((r) => r.strategy.ech)) {
      final pair = target
          .where(
            (r) =>
                r.strategy == good.strategy.plainPair &&
                r.address == good.address,
          )
          .toList();
      if (pair.length == report.config.attempts &&
          pair.every(
            (r) =>
                r.state == ProbeState.failed &&
                r.errorKind != 'certificate' &&
                r.errorKind != 'tls',
          )) {
        evidence.add('${good.address ?? '域名'}：普通 TLS 失败，ECH 成功。');
      }
    }
    final direct = report.results.where(
      (r) =>
          r.path == NetworkPath.direct &&
          r.host == host &&
          r.strategy == Strategy.baseline,
    );
    if (path == NetworkPath.proxy &&
        baseline.isNotEmpty &&
        baseline.every((r) => r.state == ProbeState.failed) &&
        direct.any((r) => r.reachable)) {
      evidence.add('目标直连可达，代理普通 TLS 失败。');
    }
    if (target.any((r) => r.configSource != null && r.configSource != host)) {
      evidence.add('使用共享 ECH 配置；仍验证原域名证书。');
    }
    evidence.add('DNS 差异不单独证明污染。推荐仅基于本次测试。');
    return Assessment(
      title: title,
      summary: summary,
      tone: tone,
      ech: ech,
      ip: ip,
      doh: doh,
      evidence: evidence,
      recommended: minimum,
    );
  }

  static int _cost(Strategy s) => switch (s) {
    Strategy.baseline => 0,
    Strategy.systemIp => 1,
    Strategy.dohIp => 2,
    Strategy.manualIp => 3,
    Strategy.echHost => 4,
    Strategy.echSystemIp => 5,
    Strategy.echDohIp => 6,
    Strategy.echManualIp => 7,
    Strategy.cloudflareIp => 3,
    Strategy.echCloudflareIp => 7,
  };
}
