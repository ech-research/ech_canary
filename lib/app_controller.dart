import 'package:flutter/foundation.dart';

import 'data/scan_store.dart';
import 'diagnostics/runner.dart';
import 'domain/models.dart';

class AppController extends ChangeNotifier {
  final _runner = DiagnosticRunner();
  final _store = ScanStore();
  ScanConfig _config = const ScanConfig();
  ScanReport? _report;
  List<ScanReport> _history = const [];
  bool _loading = true, _running = false, _stopping = false, _disposed = false;
  String? _message;
  int _completed = 0, _total = 0;

  ScanConfig get config => _config;
  ScanReport? get report => _report;
  List<ScanReport> get history => _history;
  bool get loading => _loading;
  bool get running => _running;
  bool get stopping => _stopping;
  String? get message => _message;
  int get completed => _completed;
  int get total => _total;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    try {
      _config = await _store.loadConfig();
    } catch (_) {
      _message = '设置读取失败，请重新填写测试域名。';
    }
    try {
      _history = List.unmodifiable(await _store.loadReports());
    } catch (_) {
      _message = '历史记录暂时无法读取。';
    }
    _loading = false;
    _notify();
  }

  Future<void> saveConfig(ScanConfig next) async {
    if (running) throw StateError('请先结束测试，再修改设置');
    final error = next.validate(requireTarget: false);
    if (error != null) throw ArgumentError(error);
    await _store.saveConfig(next);
    _config = next;
    _notify();
  }

  Future<void> start() async {
    if (running || loading) return;
    final invalid = config.validate();
    if (invalid != null) {
      _message = invalid;
      _notify();
      return;
    }
    _running = true;
    _stopping = false;
    _report = null;
    _message = null;
    _total = 0;
    _completed = 0;
    _notify();
    try {
      final result = await _runner.run(
        config,
        onProgress: (progress) {
          _report = progress.report;
          _completed = progress.completed;
          _total = progress.total;
          _notify();
        },
      );
      _report = result;
      _history = List.unmodifiable([result, ...history].take(20));
      try {
        await _store.saveReport(result);
      } catch (_) {
        _message = '结果未能保存到历史记录，可导出报告备份。';
      }
    } catch (_) {
      _message = '无法开始测试，请检查设置后重试。';
    } finally {
      _running = false;
      _stopping = false;
      _notify();
    }
  }

  void cancel() {
    if (!running || stopping) return;
    _stopping = true;
    _runner.cancel();
    _notify();
  }

  void openReport(ScanReport selected) {
    if (running) return;
    _report = selected;
    _notify();
  }

  void newTest() {
    if (running) return;
    _report = null;
    _message = null;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _runner.cancel();
    super.dispose();
  }
}
