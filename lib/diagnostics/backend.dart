import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ech_http/ech_http.dart';
import 'package:http/http.dart' as http;

import '../domain/models.dart';
import 'cancellation.dart';
import 'ip_transport.dart';

class ProbeJob {
  const ProbeJob(
    this.uri,
    this.path,
    this.strategy,
    this.attempt,
    this.discovery, {
    this.address,
  });
  final Uri uri;
  final NetworkPath path;
  final Strategy strategy;
  final int attempt;
  final Discovery discovery;
  final String? address;
}

abstract interface class DiagnosticBackend {
  Future<Discovery> discover(
    Uri uri,
    NetworkPath path,
    ScanConfig config,
    Cancellation cancel,
  );
  Future<ProbeResult> probe(
    ProbeJob job,
    ScanConfig config,
    Cancellation cancel,
  );
}

class NativeDiagnosticBackend implements DiagnosticBackend {
  EchClient _client(
    ScanConfig config,
    NetworkPath path, {
    EchResolver? resolver,
  }) => EchClient(
    proxy: config.proxyFor(path),
    resolver: resolver,
    timeout: config.timeout,
    connectTimeout: config.timeout,
    maxResponseBytes: 1024 * 1024,
  );

  @override
  Future<Discovery> discover(
    Uri uri,
    NetworkPath path,
    ScanConfig config,
    Cancellation cancel,
  ) async {
    final notes = <String>[];
    var systemIps = <String>[];
    try {
      systemIps = (await cancel.bind(
        InternetAddress.lookup(uri.host),
        config.timeout,
      )).map((a) => a.address).toSet().toList();
      notes.add('系统 DNS 为本机解析；代理的域名 CONNECT 由代理自行解析。');
    } on ScanCancelled {
      rethrow;
    } catch (e) {
      notes.add('系统 DNS 失败：$e');
    }
    var dohIps = <String>[];
    String? configList, source, endpointUsed;
    for (final endpointText in config.dohEndpoints) {
      cancel.check();
      final client = _client(config, path);
      final unregister = cancel.register(client.close);
      final endpoint = Uri.parse(endpointText);
      final watch = Stopwatch()..start();
      try {
        Future<List<Map<String, dynamic>>> query(String host, int type) async {
          final response = await cancel.bind(
            client.send(
              http.Request(
                  'GET',
                  endpoint.replace(
                    queryParameters: {
                      ...endpoint.queryParameters,
                      'name': host,
                      'type': '$type',
                    },
                  ),
                )
                ..followRedirects = false
                ..headers['accept'] = 'application/dns-json',
            ),
            config.timeout,
          );
          if (response.statusCode != 200) {
            throw HttpException('DoH HTTP ${response.statusCode}');
          }
          final body = await cancel.bind(
            response.stream.bytesToString(),
            config.timeout,
          );
          final value = jsonDecode(body);
          if (value is! Map<String, dynamic> || value['Status'] != 0) {
            throw FormatException(
              'DNS 响应状态 ${value is Map ? value['Status'] : '无效'}',
            );
          }
          return (value['Answer'] as List? ?? [])
              .whereType<Map<String, dynamic>>()
              .toList();
        }

        // Preserve successful DNS records when another record type fails.
        final records = <int, List<Map<String, dynamic>>>{};
        await Future.wait(
          [1, 28, 65].map((type) async {
            try {
              records[type] = await query(uri.host, type);
            } on ScanCancelled {
              rethrow;
            } catch (e) {
              notes.add('${endpoint.host} TYPE$type：$e');
            }
          }),
        );
        final ips = <String>[];
        for (final type in [1, 28]) {
          for (final rr in records[type] ?? <Map<String, dynamic>>[]) {
            if (rr['type'] == type && rr['data'] is String) {
              final ip = InternetAddress.tryParse(rr['data'] as String);
              if (ip != null) ips.add(ip.address);
            }
          }
        }
        if (dohIps.isEmpty && ips.isNotEmpty) {
          dohIps = ips.toSet().toList();
          endpointUsed = endpointText;
        }
        var httpsRecords = records[65] ?? <Map<String, dynamic>>[];
        // Follow HTTPS aliases for ECH config only; never borrow their IP hints.
        final visited = <String>{uri.host};
        for (
          var depth = 0;
          depth < 4 && extractConfig(httpsRecords) == null;
          depth++
        ) {
          String? alias;
          for (final rr in httpsRecords) {
            if (rr['type'] != 65) continue;
            final match = RegExp(r'^0\s+([^\s]+)').firstMatch('${rr['data']}');
            if (match != null && match.group(1) != '.') {
              alias = match.group(1)!.replaceFirst(RegExp(r'\.$'), '');
            }
          }
          if (alias == null || !visited.add(alias)) break;
          notes.add('HTTPS AliasMode：$alias');
          httpsRecords = await query(alias, 65);
        }
        var found = extractConfig(httpsRecords);
        var configHost = uri.host;
        if (found == null &&
            config.trySharedConfig &&
            uri.host != config.configDomain) {
          found = extractConfig(await query(config.configDomain, 65));
          configHost = config.configDomain;
          if (found != null) {
            notes.add('实验：借用 $configHost 的 ECH 配置，仍验证 ${uri.host} 的证书。');
          }
        }
        if (configList == null && found != null) {
          configList = found;
          source = configHost;
          notes.add('ECH 配置由 $endpointText 获取；来源 $configHost。');
        }
        notes.add(
          '${endpoint.host} · ${watch.elapsedMilliseconds} ms · IP ${ips.join(', ')} · ECH ${found == null ? '未发现' : '已发现'}',
        );
        if (dohIps.isNotEmpty && configList != null) break;
      } on ScanCancelled {
        rethrow;
      } catch (e) {
        notes.add('${endpoint.host}：$e');
      } finally {
        unregister();
        client.close();
      }
    }
    return Discovery(
      host: uri.host,
      path: path,
      systemIps: systemIps,
      dohIps: dohIps,
      configList: configList,
      configSource: source,
      endpoint: endpointUsed,
      notes: notes,
    );
  }

  static String? extractConfig(List<Map<String, dynamic>> records) {
    for (final rr in records) {
      if (rr['type'] != 65 || rr['data'] is! String) continue;
      final match = RegExp(r'(?:^|\s)ech="?([A-Za-z0-9+/=]+)')
          .firstMatch(rr['data'] as String);
      if (match == null) continue;
      try {
        return EchRoute(configList: match.group(1)!).configList;
      } on FormatException {
        continue;
      } on ArgumentError {
        continue;
      }
    }
    return null;
  }

  @override
  Future<ProbeResult> probe(
    ProbeJob job,
    ScanConfig config,
    Cancellation cancel,
  ) async {
    final watch = Stopwatch()..start();
    EchClient? native;
    IpTransport? transport;
    void Function()? unregister;
    var stage = '连接 / TLS';
    try {
      cancel.check();
      int status;
      var accepted = false, retries = 0;
      String? server, location;
      if (job.address != null && !job.strategy.ech) {
        transport = IpTransport(
          address: job.address!,
          timeout: config.timeout,
          proxy: config.proxyFor(job.path),
        );
        unregister = cancel.register(transport.close);
        final response = await cancel.bind(
          transport.getHeaders(job.uri),
          config.timeout,
        );
        status = response.statusCode;
        server = response.headers['server'];
        location = response.headers['location'];
      } else {
        native = _client(
          config,
          job.path,
          resolver: job.strategy.ech
              ? StaticEchResolver({
                  job.uri.host: EchRoute(
                    configList: job.discovery.configList!,
                    addresses: job.address == null ? const [] : [job.address!],
                  ),
                })
              : null,
        );
        unregister = cancel.register(native.close);
        final response = await cancel.bind(
          native.send(
            http.Request('GET', job.uri)
              ..followRedirects = false
              ..headers['user-agent'] =
                  'ECH-Canary/1.0 (connectivity diagnostics)',
          ),
          config.timeout,
        );
        status = response.statusCode;
        accepted = response.echAccepted;
        retries = response.echRetries;
        server = response.headers['server'];
        location = response.headers['location'];
        stage = 'HTTP';
        await response.stream.listen(null).cancel();
      }
      final ok = status >= 200 && status < 400;
      return ProbeResult(
        host: job.uri.host,
        path: job.path,
        strategy: job.strategy,
        attempt: job.attempt,
        state: job.strategy.ech && !accepted
            ? ProbeState.failed
            : ok
            ? ProbeState.success
            : ProbeState.httpError,
        elapsedMs: watch.elapsedMilliseconds,
        address: job.address,
        statusCode: status,
        echAccepted: accepted,
        echRetries: retries,
        configSource: job.strategy.ech ? job.discovery.configSource : null,
        server: server,
        location: location,
        detail:
            'HTTP $status${accepted ? ' · ECH 已接受' : ''}${location == null ? '' : ' · 重定向未跟随'}'
            '${ok ? '' : ' · TLS 可达，但服务返回应用层错误'}'
            '${job.address != null && !job.strategy.ech ? ' · Dart TLS / 系统信任库' : ' · ech_http / 内置信任库'}',
      );
    } catch (error) {
      return ProbeResult(
        host: job.uri.host,
        path: job.path,
        strategy: job.strategy,
        attempt: job.attempt,
        state: error is ScanCancelled || cancel.cancelled
            ? ProbeState.cancelled
            : ProbeState.failed,
        elapsedMs: watch.elapsedMilliseconds,
        address: job.address,
        detail: '$stage：$error',
        errorKind: _errorKind(error),
        nativeCode: error is EchException ? error.nativeCode : null,
        configSource: job.strategy.ech ? job.discovery.configSource : null,
      );
    } finally {
      unregister?.call();
      native?.close();
      transport?.close();
    }
  }

  static String _errorKind(Object error) {
    if (error is ScanCancelled) return 'cancelled';
    if (error is TimeoutException) return 'timeout';
    if (error is TlsException) return 'tls';
    if (error is SocketException) return 'socket';
    if (error is EchException) {
      return switch (error.nativeCode) {
        5 || 6 => 'dns',
        7 => 'connect',
        28 => 'timeout',
        35 => 'tls',
        60 => 'certificate',
        56 => 'receive_or_proxy',
        _ => 'ech_transport',
      };
    }
    return 'protocol';
  }
}
