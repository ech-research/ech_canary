import 'dart:io';

import 'package:ech_canary/diagnostics/runner.dart';
import 'package:ech_canary/domain/assessment.dart';
import 'package:ech_canary/domain/models.dart';

Future<void> main(List<String> args) async {
  String? option(String name) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length && !args[i + 1].startsWith('--')
        ? args[i + 1]
        : null;
  }

  final target = option('--target');
  if (target == null) {
    stderr.writeln(
      '用法：dart run tool/diagnose.dart --target <受限域名或 HTTPS 地址> [--proxy http://主机:端口] [--quick]',
    );
    exitCode = 64;
    return;
  }
  final proxy = option('--proxy');
  final config = ScanConfig(
    target: ScanConfig.httpsInput(target),
    proxy: proxy ?? '',
    paths: [NetworkPath.direct, if (proxy != null) NetworkPath.proxy],
    attempts: args.contains('--quick') ? 1 : 2,
    forceCloudflare: !args.contains('--no-cloudflare'),
  );
  final runner = DiagnosticRunner();
  final interrupt = ProcessSignal.sigint.watch().listen((_) => runner.cancel());
  try {
    final report = await runner.run(
      config,
      onProgress: (p) => stdout.writeln(p.phase),
    );
    final directory = Directory('artifacts')..createSync(recursive: true);
    final file = File('${directory.path}/diagnostic-${report.id}.json');
    await file.writeAsString(report.json);
    for (final path in config.paths) {
      final assessment = Assessment.forPath(report, path);
      stdout.writeln(
        '${path.label}: ${assessment.title}\n${assessment.summary}\nECH: ${assessment.ech}\nIP: ${assessment.ip}\nDoH: ${assessment.doh}',
      );
    }
    stdout.writeln('Report: ${file.absolute.path}');
    if (report.failure != null) exitCode = 1;
  } finally {
    await interrupt.cancel();
  }
}
