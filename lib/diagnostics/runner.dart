import '../domain/models.dart';
import 'backend.dart';
import 'cancellation.dart';

class ScanProgress {
  const ScanProgress(this.report, this.phase, this.completed, this.total);
  final ScanReport report;
  final String phase;
  final int completed, total;
}

class DiagnosticRunner {
  DiagnosticRunner({DiagnosticBackend? backend})
    : _backend = backend ?? NativeDiagnosticBackend();
  final DiagnosticBackend _backend;
  Cancellation? _active;
  bool get running => _active != null;
  void cancel() => _active?.cancel();

  Future<ScanReport> run(
    ScanConfig config, {
    void Function(ScanProgress)? onProgress,
  }) async {
    if (running) throw StateError('已有检测正在运行');
    final error = config.validate();
    if (error != null) throw ArgumentError(error);
    final target = Uri.parse(config.target);
    final control = Uri.parse(config.control);
    final cancel = Cancellation();
    _active = cancel;
    final now = DateTime.now();
    final report = ScanReport(
      id: '${now.microsecondsSinceEpoch}',
      startedAt: now,
      config: config,
    );
    var completed = 0, total = 0;
    void emit(String phase) {
      report.events.add('${DateTime.now().toIso8601String()} $phase');
      onProgress?.call(ScanProgress(report, phase, completed, total));
    }

    try {
      emit('正在发现 DNS 与 ECH 配置');
      for (final path in config.paths) {
        await Future.wait(
          [control, target].map((uri) async {
            final discovery = await _backend.discover(
              uri,
              path,
              config,
              cancel,
            );
            report.discoveries.add(discovery);
            emit('${path.label} · ${discovery.host} · 配置发现完成');
          }),
        );
        cancel.check();
      }
      final jobs = <ProbeJob>[];
      // Repeat every strategy each round to avoid success-biased retries.
      for (var attempt = 1; attempt <= config.attempts; attempt++) {
        for (final d in report.discoveries) {
          final isTarget = d.host == target.host;
          final uri = isTarget ? target : control;
          for (final strategy in Strategy.values) {
            final List<String?> addresses = switch (strategy) {
              Strategy.baseline || Strategy.echHost => [null],
              Strategy.systemIp || Strategy.echSystemIp => candidates(
                d.systemIps,
                config.maxAddresses,
              ),
              Strategy.dohIp ||
              Strategy.echDohIp => candidates(d.dohIps, config.maxAddresses),
              Strategy.manualIp ||
              Strategy.echManualIp => isTarget ? config.manualIps : [],
              Strategy.cloudflareIp || Strategy.echCloudflareIp =>
                config.forceCloudflare ? config.cloudflareIps : [],
            };
            String? reason;
            if (addresses.isEmpty) {
              reason = '未启用此覆写或无可用 IP；手动 IP 仅适用于目标站点';
            }
            if (strategy.ech && d.configList == null) {
              reason = '未获得 ECH 配置；不降级为普通 TLS';
            }
            if (reason != null) {
              report.results.add(
                ProbeResult(
                  host: d.host,
                  path: d.path,
                  strategy: strategy,
                  attempt: attempt,
                  state: ProbeState.skipped,
                  elapsedMs: 0,
                  detail: reason,
                ),
              );
            } else {
              for (final address in addresses) {
                jobs.add(
                  ProbeJob(uri, d.path, strategy, attempt, d, address: address),
                );
              }
            }
          }
        }
      }
      total = jobs.length;
      var next = 0;
      Future<void> worker() async {
        while (next < jobs.length && !cancel.cancelled) {
          final job = jobs[next++];
          emit(
            '${job.path.label} · ${job.uri.host} · ${job.strategy.label} · 第 ${job.attempt} 轮',
          );
          report.results.add(await _backend.probe(job, config, cancel));
          completed++;
          onProgress?.call(
            ScanProgress(
              report,
              '已完成 $completed / $total 项请求',
              completed,
              total,
            ),
          );
        }
      }

      await Future.wait([worker(), worker()]);
      report.cancelled = cancel.cancelled;
    } on ScanCancelled {
      report.cancelled = true;
    } catch (e) {
      report.failure = '$e';
    } finally {
      cancel.cancel();
      report.finishedAt = DateTime.now();
      _active = null;
      emit(
        report.cancelled
            ? '检测已取消，保留已完成证据'
            : report.failure != null
            ? '检测异常：${report.failure}'
            : '检测完成',
      );
    }
    return report;
  }

  static List<String> candidates(List<String> ips, int limit) {
    final v4 = ips.where((ip) => !ip.contains(':')).toSet().toList();
    final v6 = ips.where((ip) => ip.contains(':')).toSet().toList();
    final mixed = <String>[];
    for (var i = 0; i < v4.length || i < v6.length; i++) {
      if (i < v4.length) mixed.add(v4[i]);
      if (i < v6.length) mixed.add(v6[i]);
    }
    return mixed.take(limit).toList();
  }
}
