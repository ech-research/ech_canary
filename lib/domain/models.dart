import 'dart:convert';
import 'dart:io';

enum NetworkPath {
  direct('直连'),
  proxy('前置代理');

  const NetworkPath(this.label);
  final String label;
}

enum Strategy {
  baseline('普通连接', false, false),
  systemIp('系统 IP', false, true),
  dohIp('DoH IP', false, true),
  echHost('ECH', true, false),
  echSystemIp('ECH + 系统 IP', true, true),
  echDohIp('ECH + DoH IP', true, true),
  manualIp('指定 IP', false, true),
  echManualIp('ECH + 手动 IP', true, true),
  cloudflareIp('Cloudflare IP', false, true),
  echCloudflareIp('ECH + Cloudflare IP', true, true);

  const Strategy(this.label, this.ech, this.overridesIp);
  final String label;
  final bool ech;
  final bool overridesIp;
  Strategy? get plainPair => switch (this) {
    echHost => baseline,
    echSystemIp => systemIp,
    echDohIp => dohIp,
    echManualIp => manualIp,
    echCloudflareIp => cloudflareIp,
    _ => null,
  };
}

enum ProbeState { success, httpError, failed, skipped, cancelled }

class ScanConfig {
  const ScanConfig({
    this.target = '',
    this.control = 'https://crypto.cloudflare.com/cdn-cgi/trace',
    this.proxy = '',
    this.dohEndpoints = const [
      'https://dns.alidns.com/resolve',
      'https://cloudflare-dns.com/dns-query',
      'https://dns.google/resolve',
    ],
    this.manualIps = const [],
    this.configDomain = 'crypto.cloudflare.com',
    this.trySharedConfig = true,
    this.forceCloudflare = true,
    this.cloudflareIps = const ['104.16.0.1', '104.16.0.2'],
    this.paths = const [NetworkPath.direct],
    this.attempts = 2,
    this.timeoutSeconds = 8,
    this.maxAddresses = 2,
  });
  final String target, control, proxy, configDomain;
  final List<String> dohEndpoints, manualIps, cloudflareIps;
  final bool trySharedConfig, forceCloudflare;
  final List<NetworkPath> paths;
  final int attempts, timeoutSeconds, maxAddresses;
  Duration get timeout => Duration(seconds: timeoutSeconds);
  Uri? proxyFor(NetworkPath path) =>
      path == NetworkPath.proxy ? Uri.parse(proxy) : null;
  static String httpsInput(String value) {
    final text = value.trim();
    return text.isNotEmpty && !text.contains('://') ? 'https://$text' : text;
  }

  ScanConfig copyWith({
    String? target,
    String? control,
    String? proxy,
    List<String>? dohEndpoints,
    List<String>? manualIps,
    String? configDomain,
    bool? trySharedConfig,
    bool? forceCloudflare,
    List<String>? cloudflareIps,
    List<NetworkPath>? paths,
    int? attempts,
    int? timeoutSeconds,
    int? maxAddresses,
  }) => ScanConfig(
    target: target ?? this.target,
    control: control ?? this.control,
    proxy: proxy ?? this.proxy,
    dohEndpoints: dohEndpoints ?? this.dohEndpoints,
    manualIps: manualIps ?? this.manualIps,
    configDomain: configDomain ?? this.configDomain,
    trySharedConfig: trySharedConfig ?? this.trySharedConfig,
    forceCloudflare: forceCloudflare ?? this.forceCloudflare,
    cloudflareIps: cloudflareIps ?? this.cloudflareIps,
    paths: paths ?? this.paths,
    attempts: attempts ?? this.attempts,
    timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
    maxAddresses: maxAddresses ?? this.maxAddresses,
  );

  String? validate({bool requireTarget = true}) {
    if (requireTarget && target.isEmpty) return '请输入要测试的受限域名。';
    for (final entry in {
      if (target.isNotEmpty) '测试地址': target,
      '测试基线': control,
      for (var i = 0; i < dohEndpoints.length; i++)
        'DNS 服务 ${i + 1}': dohEndpoints[i],
    }.entries) {
      final value = entry.value;
      final uri = Uri.tryParse(value);
      if (uri == null ||
          uri.scheme != 'https' ||
          !_validHost(uri.host) ||
          uri.userInfo.isNotEmpty ||
          uri.fragment.isNotEmpty ||
          uri.port != 443) {
        return '${entry.key}需为有效的 HTTPS 地址，不含账号、密码或 # 片段，端口为 443。';
      }
    }
    if (target.isNotEmpty &&
        Uri.parse(target).host == Uri.parse(control).host) {
      return '目标与测试基线需使用不同域名。';
    }
    final p = Uri.tryParse(proxy);
    if (paths.contains(NetworkPath.proxy) &&
        (p == null ||
            p.scheme != 'http' ||
            !_validHost(p.host) ||
            p.port <= 0 ||
            p.port > 65535 ||
            p.userInfo.isNotEmpty ||
            p.hasQuery ||
            p.hasFragment ||
            (p.path.isNotEmpty && p.path != '/'))) {
      return '前置代理格式为 http://主机:端口，不含账号或密码。';
    }
    if (paths.isEmpty || dohEndpoints.isEmpty || dohEndpoints.length > 3) {
      return '至少选择一条路径及 1–3 个 DNS JSON DoH 服务。';
    }
    if (attempts < 1 ||
        attempts > 3 ||
        timeoutSeconds < 3 ||
        timeoutSeconds > 30 ||
        maxAddresses < 1 ||
        maxAddresses > 4) {
      return '重复次数 1–3，超时 3–30 秒，候选 IP 数 1–4。';
    }
    if (manualIps.length > 4 ||
        manualIps.any((ip) => InternetAddress.tryParse(ip) == null)) {
      return '手动覆写最多支持 4 个 IPv4 / IPv6 地址。';
    }
    if (forceCloudflare &&
        (cloudflareIps.isEmpty ||
            cloudflareIps.length > 4 ||
            cloudflareIps.any((ip) => InternetAddress.tryParse(ip) == null))) {
      return 'Cloudflare 覆写需配置 1–4 个有效 IP。';
    }
    if (trySharedConfig &&
        !RegExp(r'^(?=.{1,253}$)[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?$')
            .hasMatch(configDomain)) {
      return '共享配置来源应填写域名，不含协议或路径。';
    }
    return null;
  }

  static bool _validHost(String host) =>
      InternetAddress.tryParse(host) != null ||
      (host.isNotEmpty &&
          host.length <= 253 &&
          host
              .split('.')
              .every(
                (label) =>
                    RegExp(r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$')
                        .hasMatch(label),
              ));

  Map<String, dynamic> toJson() => {
    'target': target,
    'control': control,
    'proxy': proxy,
    'dohEndpoints': dohEndpoints,
    'manualIps': manualIps,
    'configDomain': configDomain,
    'trySharedConfig': trySharedConfig,
    'paths': paths.map((e) => e.name).toList(),
    'attempts': attempts,
    'timeoutSeconds': timeoutSeconds,
    'maxAddresses': maxAddresses,
    'forceCloudflare': forceCloudflare,
    'cloudflareIps': cloudflareIps,
  };
  factory ScanConfig.fromJson(Map<String, dynamic> j) => ScanConfig(
    target: j['target'] as String,
    control: j['control'] as String,
    proxy: j['proxy'] as String,
    configDomain: j['configDomain'] as String,
    dohEndpoints: List<String>.from(j['dohEndpoints'] as List),
    manualIps: List<String>.from(j['manualIps'] as List),
    trySharedConfig: j['trySharedConfig'] as bool,
    paths: (j['paths'] as List)
        .map((v) => NetworkPath.values.byName(v as String))
        .toList(),
    attempts: j['attempts'] as int,
    timeoutSeconds: j['timeoutSeconds'] as int,
    maxAddresses: j['maxAddresses'] as int,
    forceCloudflare: j['forceCloudflare'] as bool? ?? false,
    cloudflareIps: j['cloudflareIps'] == null
        ? const ['104.16.0.1', '104.16.0.2']
        : List<String>.from(j['cloudflareIps'] as List),
  );
}

class Discovery {
  const Discovery({
    required this.host,
    required this.path,
    this.systemIps = const [],
    this.dohIps = const [],
    this.configList,
    this.configSource,
    this.endpoint,
    this.notes = const [],
  });
  final String host;
  final NetworkPath path;
  final List<String> systemIps, dohIps, notes;
  final String? configList, configSource, endpoint;
  bool get borrowed => configSource != null && configSource != host;
  Map<String, dynamic> toJson() => {
    'host': host,
    'path': path.name,
    'systemIps': systemIps,
    'dohIps': dohIps,
    'configList': configList,
    'configSource': configSource,
    'endpoint': endpoint,
    'notes': notes,
  };
  factory Discovery.fromJson(Map<String, dynamic> j) => Discovery(
    host: j['host'] as String,
    path: NetworkPath.values.byName(j['path'] as String),
    systemIps: List<String>.from(j['systemIps'] as List),
    dohIps: List<String>.from(j['dohIps'] as List),
    configList: j['configList'] as String?,
    configSource: j['configSource'] as String?,
    endpoint: j['endpoint'] as String?,
    notes: List<String>.from(j['notes'] as List),
  );
}

class ProbeResult {
  const ProbeResult({
    required this.host,
    required this.path,
    required this.strategy,
    required this.attempt,
    required this.state,
    required this.elapsedMs,
    required this.detail,
    this.address,
    this.statusCode,
    this.echAccepted = false,
    this.echRetries = 0,
    this.errorKind,
    this.nativeCode,
    this.configSource,
    this.server,
    this.location,
  });
  final String host, detail;
  final NetworkPath path;
  final Strategy strategy;
  final int attempt, elapsedMs, echRetries;
  final ProbeState state;
  final String? address, errorKind, configSource, server, location;
  final int? statusCode, nativeCode;
  final bool echAccepted;
  bool get reachable =>
      state == ProbeState.success || state == ProbeState.httpError;
  bool get usable =>
      state == ProbeState.success && (!strategy.ech || echAccepted);
  String get groupKey => '${path.name}|$host|${strategy.name}|${address ?? ""}';
  Map<String, dynamic> toJson() => {
    'host': host,
    'path': path.name,
    'strategy': strategy.name,
    'attempt': attempt,
    'state': state.name,
    'elapsedMs': elapsedMs,
    'detail': detail,
    'address': address,
    'statusCode': statusCode,
    'echAccepted': echAccepted,
    'echRetries': echRetries,
    'errorKind': errorKind,
    'nativeCode': nativeCode,
    'configSource': configSource,
    'server': server,
    'location': location,
  };
  factory ProbeResult.fromJson(Map<String, dynamic> j) => ProbeResult(
    host: j['host'] as String,
    path: NetworkPath.values.byName(j['path'] as String),
    strategy: Strategy.values.byName(j['strategy'] as String),
    attempt: j['attempt'] as int,
    state: ProbeState.values.byName(j['state'] as String),
    elapsedMs: j['elapsedMs'] as int,
    detail: j['detail'] as String,
    address: j['address'] as String?,
    statusCode: j['statusCode'] as int?,
    echAccepted: j['echAccepted'] as bool,
    echRetries: j['echRetries'] as int,
    errorKind: j['errorKind'] as String?,
    nativeCode: j['nativeCode'] as int?,
    configSource: j['configSource'] as String?,
    server: j['server'] as String?,
    location: j['location'] as String?,
  );
}

class ScanReport {
  ScanReport({
    required this.id,
    required this.startedAt,
    required this.config,
    this.finishedAt,
    this.cancelled = false,
    this.failure,
    List<Discovery>? discoveries,
    List<ProbeResult>? results,
    List<String>? events,
  }) : discoveries = discoveries ?? [],
       results = results ?? [],
       events = events ?? [];
  final String id;
  final DateTime startedAt;
  final ScanConfig config;
  DateTime? finishedAt;
  bool cancelled;
  String? failure;
  final List<Discovery> discoveries;
  final List<ProbeResult> results;
  final List<String> events;
  bool get complete => finishedAt != null && !cancelled && failure == null;
  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'app': 'ECH Canary',
    'id': id,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'config': config.toJson(),
    'cancelled': cancelled,
    'failure': failure,
    'discoveries': discoveries.map((e) => e.toJson()).toList(),
    'results': results.map((e) => e.toJson()).toList(),
    'events': events,
  };
  String get json => const JsonEncoder.withIndent('  ').convert(toJson());
  factory ScanReport.fromJson(Map<String, dynamic> j) => ScanReport(
    id: j['id'] as String,
    startedAt: DateTime.parse(j['startedAt'] as String),
    finishedAt: j['finishedAt'] == null
        ? null
        : DateTime.parse(j['finishedAt'] as String),
    config: ScanConfig.fromJson(j['config'] as Map<String, dynamic>),
    cancelled: j['cancelled'] as bool,
    failure: j['failure'] as String?,
    discoveries: (j['discoveries'] as List)
        .map((e) => Discovery.fromJson(e as Map<String, dynamic>))
        .toList(),
    results: (j['results'] as List)
        .map((e) => ProbeResult.fromJson(e as Map<String, dynamic>))
        .toList(),
    events: List<String>.from(j['events'] as List),
  );
}
