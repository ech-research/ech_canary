import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ech_canary/diagnostics/backend.dart';
import 'package:ech_canary/diagnostics/cancellation.dart';
import 'package:ech_canary/diagnostics/ip_transport.dart';
import 'package:ech_canary/diagnostics/runner.dart';
import 'package:ech_canary/domain/assessment.dart';
import 'package:ech_canary/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

const echConfig = 'AAT+DQAA';
const testConfig = ScanConfig(
  target: 'https://api.bgm.tv/',
  proxy: 'http://127.0.0.1:8080',
  paths: [NetworkPath.direct, NetworkPath.proxy],
);

class FakeBackend implements DiagnosticBackend {
  final jobs = <ProbeJob>[];
  bool withEch = true;
  Completer<void>? gate;
  @override
  Future<Discovery> discover(
    Uri uri,
    NetworkPath path,
    ScanConfig config,
    Cancellation cancel,
  ) async {
    return Discovery(
      host: uri.host,
      path: path,
      systemIps: ['192.0.2.1'],
      dohIps: ['203.0.113.1'],
      configList: withEch ? echConfig : null,
      configSource: uri.host,
    );
  }

  @override
  Future<ProbeResult> probe(
    ProbeJob job,
    ScanConfig config,
    Cancellation cancel,
  ) async {
    jobs.add(job);
    if (gate != null) {
      try {
        await cancel.bind(gate!.future, config.timeout);
      } on ScanCancelled {
        return result(
          job.strategy,
          state: ProbeState.cancelled,
          host: job.uri.host,
        );
      }
    }
    return result(
      job.strategy,
      host: job.uri.host,
      path: job.path,
      attempt: job.attempt,
      address: job.address,
    );
  }
}

ProbeResult result(
  Strategy strategy, {
  String host = 'api.bgm.tv',
  NetworkPath path = NetworkPath.proxy,
  int attempt = 1,
  String? address,
  ProbeState state = ProbeState.success,
  int? status,
  bool? accepted,
}) => ProbeResult(
  host: host,
  path: path,
  strategy: strategy,
  attempt: attempt,
  state: state,
  elapsedMs: 20,
  detail: 'test evidence',
  address: address,
  echAccepted: accepted ?? (strategy.ech && state == ProbeState.success),
  statusCode: status ?? (state == ProbeState.success ? 200 : null),
  errorKind: state == ProbeState.failed ? 'timeout' : null,
);

ScanReport report(
  List<ProbeResult> rows, {
  bool cancelled = false,
  int attempts = 2,
}) => ScanReport(
  id: 'test',
  startedAt: DateTime(2026),
  finishedAt: DateTime(2026, 1, 1, 0, 1),
  config: testConfig.copyWith(attempts: attempts),
  results: rows,
  cancelled: cancelled,
);

void main() {
  test(
    'cancelling IP control closes TCP during a stalled TLS handshake',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final hello = Completer<void>();
      final disconnected = Completer<void>();
      Socket? accepted;
      var connected = false;
      final listener = server.listen((socket) {
        accepted = socket;
        socket.listen(
          (data) {
            if (!connected) {
              connected = true;
              socket.write('HTTP/1.1 200 Connection established\r\n\r\n');
            } else if (!hello.isCompleted) {
              hello.complete();
            }
          },
          onDone: () {
            if (!disconnected.isCompleted) disconnected.complete();
          },
        );
      });
      final transport = IpTransport(
        address: '104.16.0.1',
        timeout: const Duration(seconds: 10),
        proxy: Uri.parse('http://127.0.0.1:${server.port}'),
      );
      try {
        final pending = expectLater(
          transport.getHeaders(Uri.parse('https://example.com/')),
          throwsA(isA<Exception>()),
        );
        await hello.future.timeout(const Duration(seconds: 2));
        transport.close();
        await pending.timeout(const Duration(seconds: 2));
        await disconnected.future.timeout(const Duration(seconds: 2));
      } finally {
        transport.close();
        accepted?.destroy();
        await listener.cancel();
        await server.close();
      }
    },
  );
  test(
    'Cloudflare override covers arbitrary target AND control on every path',
    () async {
      final backend = FakeBackend();
      final runner = DiagnosticRunner(backend: backend);
      const config = ScanConfig(
        target: 'https://unrelated.example/',
        proxy: 'http://127.0.0.1:8080',
        paths: [NetworkPath.direct, NetworkPath.proxy],
        control: 'https://reference.example/',
        forceCloudflare: true,
        attempts: 2,
      );
      final r = await runner.run(config);
      expect(r.complete, isTrue);
      for (final path in NetworkPath.values) {
        for (final host in ['unrelated.example', 'reference.example']) {
          for (final strategy in [
            Strategy.cloudflareIp,
            Strategy.echCloudflareIp,
          ]) {
            final jobs = backend.jobs
                .where(
                  (j) =>
                      j.path == path &&
                      j.uri.host == host &&
                      j.strategy == strategy,
                )
                .toList();
            expect(jobs.length, 4);
            expect(
              jobs.map((j) => j.address).toSet(),
              config.cloudflareIps.toSet(),
            );
            expect(jobs.every((j) => j.address != '203.0.113.1'), isTrue);
            expect(jobs.map((j) => j.attempt).toSet(), {1, 2});
          }
        }
      }
    },
  );
  test(
    'missing ECH config skips ECH but still tests forced Cloudflare plain TLS',
    () async {
      final backend = FakeBackend()..withEch = false;
      final r = await DiagnosticRunner(backend: backend).run(testConfig);
      expect(backend.jobs.any((j) => j.strategy.ech), isFalse);
      expect(
        backend.jobs.where((j) => j.strategy == Strategy.cloudflareIp).length,
        16,
      );
      expect(
        r.results
            .where((r) => r.strategy == Strategy.echCloudflareIp)
            .every((r) => r.state == ProbeState.skipped),
        isTrue,
      );
    },
  );
  test('cancellation stops queued work and retains partial report', () async {
    final backend = FakeBackend()..gate = Completer<void>();
    final runner = DiagnosticRunner(backend: backend);
    final future = runner.run(testConfig);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    runner.cancel();
    final r = await future.timeout(const Duration(seconds: 1));
    expect(r.cancelled, isTrue);
    expect(r.complete, isFalse);
    expect(backend.jobs.length, lessThanOrEqualTo(2));
    expect(runner.running, isFalse);
  });
  test('HTTP 403 is TLS reachable, not proof of censorship', () {
    final a = Assessment.forPath(
      report([
        result(Strategy.baseline, state: ProbeState.httpError, status: 403),
        result(
          Strategy.baseline,
          state: ProbeState.httpError,
          status: 403,
          attempt: 2,
        ),
      ]),
      NetworkPath.proxy,
    );
    expect(a.title, '连接不稳定或网站响应异常');
    expect(a.recommended, isNull);
  });
  test('partial and mixed success never produce stable recommendation', () {
    final rows = [
      result(Strategy.echCloudflareIp, address: '104.16.0.1'),
      result(
        Strategy.echCloudflareIp,
        address: '104.16.0.1',
        attempt: 2,
        state: ProbeState.failed,
      ),
    ];
    expect(
      Assessment.forPath(report(rows), NetworkPath.proxy).recommended,
      isNull,
    );
    expect(
      Assessment.forPath(
        report([result(Strategy.baseline)], cancelled: true),
        NetworkPath.proxy,
      ).recommended,
      isNull,
    );
  });
  test('verified ECH flag is required, and path evidence is isolated', () {
    final rows = [
      for (var i = 1; i <= 2; i++) ...[
        result(
          Strategy.echDohIp,
          address: '1.2.3.4',
          attempt: i,
          accepted: false,
        ),
        result(Strategy.baseline, path: NetworkPath.direct, attempt: i),
        result(Strategy.baseline, state: ProbeState.failed, attempt: i),
      ],
    ];
    final a = Assessment.forPath(report(rows), NetworkPath.proxy);
    expect(a.recommended, isNull);
    expect(a.ech, '未验证');
  });
  test('Cloudflare success is independent of poisoned DoH IPs', () {
    final rows = [
      for (var i = 1; i <= 2; i++) ...[
        result(Strategy.baseline, state: ProbeState.failed, attempt: i),
        result(Strategy.echHost, state: ProbeState.failed, attempt: i),
        result(
          Strategy.echDohIp,
          state: ProbeState.failed,
          attempt: i,
          address: '203.0.113.1',
        ),
        result(
          Strategy.cloudflareIp,
          state: ProbeState.failed,
          attempt: i,
          address: '104.16.0.1',
        ),
        result(Strategy.echCloudflareIp, attempt: i, address: '104.16.0.1'),
      ],
    ];
    final a = Assessment.forPath(report(rows), NetworkPath.proxy);
    expect(a.recommended?.strategy, Strategy.echCloudflareIp);
    expect(a.ip, 'ECH 需配合覆写');
    expect(a.doh, contains('仅使用 ECH 配置'));
  });
  test('invalid inputs rejected and report round-trip retains provenance', () {
    expect(const ScanConfig(target: 'http://api.bgm.tv').validate(), isNotNull);
    expect(
      testConfig.copyWith(proxy: 'http://user:pass@localhost:8080').validate(),
      isNotNull,
    );
    expect(
      testConfig
          .copyWith(forceCloudflare: true, cloudflareIps: ['bad'])
          .validate(),
      isNotNull,
    );
    final original = report([
      result(Strategy.echCloudflareIp, address: '104.16.0.1'),
    ]);
    final copy = ScanReport.fromJson(
      jsonDecode(original.json) as Map<String, dynamic>,
    );
    expect(copy.toJson(), original.toJson());
  });
  test('ECHConfig extraction validates framing; malformed entries do not shadow valid ones', () {
    expect(
      NativeDiagnosticBackend.extractConfig([
        {'type': 65, 'data': '1 . ech="YmFk"'},
        {'type': 65, 'data': '1 . alpn="h2" ech="$echConfig"'},
      ]),
      echConfig,
    );
    expect(
      NativeDiagnosticBackend.extractConfig([
        {'type': 1, 'data': 'ech="$echConfig"'},
      ]),
      isNull,
    );
  });
  test('IP candidates include both families without duplicates', () {
    expect(
      DiagnosticRunner.candidates([
        '1.1.1.1',
        '1.1.1.1',
        '1.0.0.1',
        '2606:4700::1',
      ], 2),
      ['1.1.1.1', '2606:4700::1'],
    );
  });
  test('proxy CONNECT contains override IP, not the target hostname', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final request = Completer<String>();
    final sockets = <Socket>[];
    final subscription = server.listen((socket) {
      sockets.add(socket);
      socket.listen((bytes) {
        if (!request.isCompleted) request.complete(utf8.decode(bytes));
        socket.write('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n');
      });
    });
    final transport = IpTransport(
      address: '104.16.0.1',
      timeout: const Duration(seconds: 1),
      proxy: Uri.parse('http://127.0.0.1:${server.port}'),
    );
    try {
      await expectLater(
        transport.getHeaders(Uri.parse('https://arbitrary.example/')),
        throwsA(isA<HttpException>()),
      );
      expect(
        await request.future,
        startsWith('CONNECT 104.16.0.1:443 HTTP/1.1\r\n'),
      );
      expect(await request.future, isNot(contains('arbitrary.example')));
    } finally {
      transport.close();
      for (final socket in sockets) {
        socket.destroy();
      }
      await subscription.cancel();
      await server.close();
    }
  });
}
